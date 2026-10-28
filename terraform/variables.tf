# ──────────────────────────────────────────────
# Input Variables
# ──────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "ap-south-1"
}

variable "environment" {
  description = "Environment name, used for tagging (e.g., dev, staging, production)"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "eks-monitoring"
}

# ── VPC Variables ──

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones"
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
}

# ── EKS Variables ──

# EKS standard support currently covers 1.34, 1.35 and 1.36. A version older than
# that drops into extended support, which AWS bills at a higher hourly rate for the
# control plane. The cluster's upgrade_policy in eks.tf is set to STANDARD, so AWS
# upgrades it rather than billing extended support, but bumping this yourself
# keeps the upgrade on your schedule instead of AWS's.
variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.35"
}

variable "node_instance_types" {
  description = "EC2 instance types for the EKS managed node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 4
}

variable "node_disk_size" {
  description = "Disk size in GB for worker nodes"
  type        = number
  default     = 20
}

# Left at 0.0.0.0/0 the public API server endpoint is reachable from the entire
# internet. Authentication still applies, but the endpoint is open to anyone who
# wants to probe it. Set this to your own /32 in terraform.tfvars before apply,
# for example ["203.0.113.7/32"].
variable "public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public EKS API server endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
