# Task App 02

SQS + ECS Worker を使ったCSV出力機能

---

## 構成図

フロントエンド（CSV出力ボタン）
↓
バックエンドAPI（FastAPI）
↓ RDSのステータスをpendingに更新
↓ SQSにメッセージを送信
SQS（メッセージキュー）
↓
Worker（ECS Fargate）
↓ RDSからタスク一覧を取得
↓ CSVファイルを作成
↓ S3に保存
↓ RDSのステータスをcompleteに更新
S3（CSVファイルの保存）

---

## 使用技術

### AWS サービス
| サービス | 役割 |
|---------|------|
| SQS | メッセージキュー（非同期処理） |
| ECS Fargate | Workerコンテナの実行環境 |
| ECR | WorkerのDockerイメージの保存 |
| S3 | CSVファイルの保存 |
| CloudWatch Logs | Workerのログ管理 |
| Secrets Manager | DBパスワードの安全な管理 |
| IAM | 各サービスの権限管理 |

### ツール
| ツール | 用途 |
|--------|------|
| Python | Workerのプログラム |
| Docker | Workerのコンテナ化 |
| Terraform | インフラのコード管理（IaC） |

---

## 基本的な知識

### SQSとは？

Simple Queue Service（シンプルキューサービス）キュー（行列）の仕組み
└─ メッセージを一時的に保存する場所なぜ使うのか？
└─ CSV出力は時間がかかる処理
└─ APIサーバーで処理するとタイムアウトする
└─ SQSに「CSV出力してください」という
メッセージを入れてWorkerが非同期で処理する身近な例
└─ レストランの注文票
お客さん（フロント） → 注文票（SQS） → 厨房（Worker）
お客さんはすぐに席に戻れる！

### 非同期処理とは？

同期処理（SQSなし）
フロント → API → CSV作成 → 完了
↑
APIが完了するまでフロントは待つ
CSV作成に時間がかかるとタイムアウト！非同期処理（SQSあり）
フロント → API → SQSにメッセージ送信 → すぐにレスポンス
↓
Workerが非同期でCSV作成
↓
完了したらステータスをcompleteに更新フロントはすぐにレスポンスを受け取れる！


### Workerとは？

バックグラウンドで処理を行うサービス
今回のWorker
└─ SQSを常時監視（ポーリング）
└─ メッセージが来たらCSV出力を実行
└─ 処理が終わったらメッセージを削除
WaitTimeSeconds = 20（ロングポーリング）
└─ 20秒間メッセージを待つ
└─ APIを頻繁に呼ばなくて済む（コスト削減）


---

## ファイル構成

task-app-02/
├── worker/
│   ├── app/
│   │   └── main.py        → SQSポーリング・CSV生成・S3保存
│   ├── Dockerfile          → Workerのコンテナ設計図
│   └── requirements.txt    → 必要なPythonライブラリ
└── infra/
├── main.tf             → AWSリソースの定義
├── variables.tf        → 変数の定義
├── outputs.tf          → 出力値の定義
├── terraform.tfvars    → 変数の値（gitignore済み）
└── modules/
└── sqs/            → SQSキューの定義
├── main.tf
├── variables.tf
└── outputs.tf

---

## Workerの処理の流れ

```python
# 1. SQSからメッセージを受け取る
response = sqs_client.receive_message(
    QueueUrl=SQS_QUEUE_URL,
    WaitTimeSeconds=20
)

# 2. export_idを取得
body = json.loads(message["Body"])
export_id = body.get("export_id")

# 3. RDSからタスク一覧を取得してCSVを作成
tasks = db.query(Task).all()
writer.writerow(["ID", "タイトル", "説明", "ステータス", "作成日時"])

# 4. S3にアップロード
s3_client.put_object(
    Bucket=S3_BUCKET,
    Key=f"csv_exports/{export_id}/tasks.csv",
    Body=output.getvalue().encode("utf-8-sig")
)

# 5. ステータスをcompleteに更新
export.status = CsvExportStatus.complete
export.file_url = key
db.commit()

# 6. SQSからメッセージを削除
sqs_client.delete_message(
    QueueUrl=SQS_QUEUE_URL,
    ReceiptHandle=message["ReceiptHandle"]
)
```

---

## 環境の構築手順

### 前提条件

task-app-01のインフラが構築済みであること

### Step1: terraform.tfvarsを作成

```bash
# VPC IDの確認
aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=task-app-vpc" \
  --query "Vpcs[0].VpcId" \
  --output text \
  --region ap-northeast-1

# プライベートサブネットIDの確認
aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=task-app-private-subnet-*" \
  --query "Subnets[*].SubnetId" \
  --output text \
  --region ap-northeast-1

# Secrets ManagerのARNを確認
aws secretsmanager list-secrets \
  --region ap-northeast-1 \
  --query "SecretList[?contains(Name,'task-app')].ARN"
```

```bash
cat > infra/terraform.tfvars << 'EOF'
aws_region             = "ap-northeast-1"
s3_bucket_name         = "task-app-images-achuya-2026"
db_secret_arn          = "arn:aws:secretsmanager:ap-northeast-1:ACCOUNT_ID:secret:task-app-db-secret-XXXXXX"
ecs_cluster_name       = "task-app-cluster"
private_subnet_ids     = ["subnet-xxx", "subnet-yyy"]
vpc_id                 = "vpc-xxx"
EOF
```

### Step2: インフラを構築

```bash
cd infra
terraform init
terraform apply
```

### Step3: WorkerのDockerイメージをECRにpush

```bash
# ECRにログイン
aws ecr get-login-password --region ap-northeast-1 | \
  docker login --username AWS --password-stdin \
  ACCOUNT_ID.dkr.ecr.ap-northeast-1.amazonaws.com

# ビルド・push
docker buildx build \
  --platform linux/amd64 \
  -t ACCOUNT_ID.dkr.ecr.ap-northeast-1.amazonaws.com/task-app-worker:latest \
  --push \
  ./worker
```

### Step4: ECSサービスを更新

```bash
aws ecs update-service \
  --cluster task-app-cluster \
  --service task-app-worker-service \
  --force-new-deployment \
  --region ap-northeast-1
```

### Step5: 動作確認

```bash
# SQSにテストメッセージを送信
aws sqs send-message \
  --queue-url "https://sqs.ap-northeast-1.amazonaws.com/ACCOUNT_ID/task-app-csv-export" \
  --message-body '{"export_id": 1}' \
  --region ap-northeast-1

# Workerのログを確認
aws logs get-log-events \
  --log-group-name /ecs/task-app-worker \
  --log-stream-name $(aws logs describe-log-streams \
    --log-group-name /ecs/task-app-worker \
    --order-by LastEventTime \
    --descending \
    --query "logStreams[0].logStreamName" \
    --output text \
    --region ap-northeast-1) \
  --region ap-northeast-1 \
  --query "events[-5:].message" \
  --output text

# S3にCSVが保存されたか確認
aws s3 ls s3://task-app-images-achuya-2026/csv_exports/ \
  --recursive \
  --region ap-northeast-1
```

---

## 環境の削除手順

```bash
cd infra
terraform destroy
```

> ⚠️ task-app-01のinfraを先にdestroyしないこと！
> task-app-02はtask-app-01のVPC・ECSクラスターを使用しているため
> task-app-02を先にdestroyしてからtask-app-01をdestroyすること

---

## トラブルシューティング

### WorkerがSecrets Managerにアクセスできない場合

原因
└─ IAMポリシーのSecrets Manager ARNが古い
└─ terraform destroyとapplyでARNのサフィックスが変わる
解決方法
aws secretsmanager list-secrets 
--region ap-northeast-1 
--query "SecretList[?contains(Name,'task-app')].ARN"
→ 最新のARNをterraform.tfvarsに設定
→ terraform applyで反映

### Workerのログが出ない場合

原因
└─ PYTHONUNBUFFERED=1が設定されていない
└─ Pythonのバッファリングでログが遅延する
解決方法
└─ DockerfileにENV PYTHONUNBUFFERED=1を追加

### CSVが文字化けする場合

原因
└─ Excelで開くとUTF-8が文字化けする
解決方法
└─ encode("utf-8-sig")を使用
└─ BOM付きUTF-8でExcelが正しく認識する


---

## 注意事項

- `terraform.tfvars`にはDBパスワード等が含まれるため`.gitignore`に追加済み
- task-app-01のインフラが構築されている状態で使用すること
- destroyはtask-app-02 → task-app-01の順番で行うこと
