output "sqs_queue_url" {
  description = "SQS queue URL"
  value       = module.sqs.queue_url
}

output "worker_ecr_url" {
  description = "Worker ECR URL"
  value       = aws_ecr_repository.worker.repository_url
}