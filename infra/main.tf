provider "aws" {
  region = var.aws_region
}

# SQSキュー
module "sqs" {
  source = "./modules/sqs"
}

# Worker用ECRリポジトリ
resource "aws_ecr_repository" "worker" {
  name                 = var.worker_repository_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = var.worker_repository_name
  }
}

# Worker用IAMロール
resource "aws_iam_role" "worker" {
  name = "task-app-worker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "worker_execution" {
  role       = aws_iam_role.worker.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "worker" {
  name = "task-app-worker-policy"
  role = aws_iam_role.worker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = [module.sqs.queue_arn]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject"
        ]
        Resource = "arn:aws:s3:::${var.s3_bucket_name}/*"
      },
      {
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = ["arn:aws:secretsmanager:ap-northeast-1:058898200941:secret:task-app-db-secret-2rUtEW"]
      }
    ]
  })
}

# CloudWatch Logs
resource "aws_cloudwatch_log_group" "worker" {
  name              = "/ecs/task-app-worker"
  retention_in_days = 7
}

# Workerタスク定義
resource "aws_ecs_task_definition" "worker" {
  family                   = "task-app-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.worker.arn
  task_role_arn            = aws_iam_role.worker.arn

  container_definitions = jsonencode([
    {
      name  = "worker"
      image = "${aws_ecr_repository.worker.repository_url}:latest"
      secrets = [
        {
        name      = "DATABASE_URL"
        valueFrom = "arn:aws:secretsmanager:ap-northeast-1:058898200941:secret:task-app-db-secret-2rUtEW"
        }
      ]
      environment = [
        {
          name  = "SQS_QUEUE_URL"
          value = module.sqs.queue_url
        },
        {
          name  = "S3_BUCKET"
          value = var.s3_bucket_name
        },
        {
          name  = "AWS_REGION"
          value = var.aws_region
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/task-app-worker"
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "worker"
        }
      }
    }
  ])
}

# Workerセキュリティグループ
resource "aws_security_group" "worker" {
  name        = "task-app-worker-sg"
  description = "Security group for worker"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "task-app-worker-sg"
  }
}

# WorkerECSサービス
resource "aws_ecs_service" "worker" {
  name            = "task-app-worker-service"
  cluster         = var.ecs_cluster_name
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.worker.id]
    assign_public_ip = false
  }
}

resource "aws_iam_role_policy" "worker_execution_secrets" {
  name = "task-app-worker-execution-secrets-policy"
  role = aws_iam_role.worker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = ["arn:aws:secretsmanager:ap-northeast-1:058898200941:secret:task-app-db-secret-2rUtEW"]
      }
    ]
  })
}