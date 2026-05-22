# SQSキュー
resource "aws_sqs_queue" "csv_export" {
  name                      = var.queue_name
  message_retention_seconds = 86400
  visibility_timeout_seconds = 300

  tags = {
    Name = var.queue_name
  }
}