variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "s3_bucket_name" {
  description = "S3 bucket name"
  type        = string
}

variable "db_secret_arn" {
  description = "Database secret ARN from task-app-01"
  type        = string
}

variable "ecs_cluster_name" {
  description = "ECS cluster name from task-app-01"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs from task-app-01"
  type        = list(string)
}

variable "vpc_id" {
  description = "VPC ID from task-app-01"
  type        = string
}

variable "worker_repository_name" {
  description = "Worker ECR repository name"
  type        = string
  default     = "task-app-worker"
}