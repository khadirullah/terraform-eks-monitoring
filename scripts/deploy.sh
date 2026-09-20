#!/usr/bin/env bash
# ──────────────────────────────────────────────
# deploy.sh - One-command deployment script
# Provisions AWS infrastructure and deploys
# the monitoring stack to EKS
# ──────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[ok]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[->]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ── Pre-flight checks ──
command -v terraform >/dev/null 2>&1 || err "Terraform is not installed"
command -v kubectl >/dev/null 2>&1   || err "kubectl is not installed"
command -v aws >/dev/null 2>&1       || err "AWS CLI is not installed"

echo ""
echo "EKS monitoring stack, deploy"
echo ""

# ── Step 1: Terraform Init & Apply ──
info "Step 1/4: Provisioning AWS infrastructure with Terraform..."
cd "$PROJECT_DIR/terraform"

if [ ! -f "terraform.tfvars" ]; then
    warn "terraform.tfvars not found. Copying from example..."
    cp terraform.tfvars.example terraform.tfvars
    warn "Please edit terraform/terraform.tfvars with your values, then re-run this script."
    exit 1
fi

terraform init
terraform plan -out=tfplan

echo ""
warn "The plan above creates real, billable AWS resources:"
warn "  EKS control plane  - flat hourly rate per cluster, runs until destroyed"
warn "  NAT gateway        - hourly, plus per-GB processing, bills even when idle"
warn "  2x t3.medium nodes - hourly"
warn "  Elastic IP         - hourly while allocated"
echo ""
warn "Run scripts/destroy.sh when you are finished. An EKS cluster left running"
warn "over a month costs more than this whole project is worth."
echo ""
read -r -p "Type 'apply' to create these resources: " CONFIRM
[ "$CONFIRM" = "apply" ] || { rm -f tfplan; err "Aborted. Nothing created."; }

terraform apply tfplan
rm -f tfplan
log "AWS infrastructure provisioned successfully"

# ── Step 2: Configure kubectl ──
info "Step 2/4: Configuring kubectl for EKS cluster..."
CLUSTER_NAME=$(terraform output -raw cluster_name)
AWS_REGION=$(terraform output -raw aws_region 2>/dev/null || echo "ap-south-1")
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
log "kubectl configured for cluster: $CLUSTER_NAME"

# ── Step 3: Deploy Monitoring Stack ──
info "Step 3/4: Deploying monitoring stack to Kubernetes..."
cd "$PROJECT_DIR"
# The namespace goes first on its own. kubectl applies a directory in file name
# order, and alertmanager-deployment.yaml sorts before namespace.yaml.
kubectl apply -f k8s/monitoring/namespace.yaml
kubectl apply -f k8s/monitoring/
log "Monitoring stack deployed"

# ── Step 4: Wait for pods ──
info "Step 4/4: Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus -n monitoring --timeout=120s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n monitoring --timeout=120s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=alertmanager -n monitoring --timeout=120s
log "All monitoring pods are running"

echo ""
echo "Deployment complete."
echo ""
echo "Reach the dashboards with port-forward, one per terminal:"
echo ""
echo "  kubectl port-forward -n monitoring svc/grafana      3000:3000"
echo "  kubectl port-forward -n monitoring svc/prometheus   9090:9090"
echo "  kubectl port-forward -n monitoring svc/alertmanager 9093:9093"
echo ""
echo "Grafana admin password comes from the grafana-admin secret:"
echo ""
echo "  kubectl get secret -n monitoring grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d"
echo ""
warn "This cluster is billing right now. Run scripts/destroy.sh when you are done."
echo ""
