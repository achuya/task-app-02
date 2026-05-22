import boto3
import json
import os
import csv
import io
import time
from sqlalchemy import create_engine, Column, Integer, String, Text, DateTime, Enum
from sqlalchemy.orm import declarative_base, sessionmaker
from sqlalchemy.sql import func
import enum
import sys


# 環境変数
DATABASE_URL = os.getenv("DATABASE_URL", "")
SQS_QUEUE_URL = os.getenv("SQS_QUEUE_URL", "")
S3_BUCKET = os.getenv("S3_BUCKET", "")
AWS_REGION = os.getenv("AWS_REGION", "ap-northeast-1")

# DB設定
try:
    parsed = json.loads(DATABASE_URL)
    if isinstance(parsed, dict) and "DATABASE_URL" in parsed:
        DATABASE_URL = parsed["DATABASE_URL"]
except (json.JSONDecodeError, TypeError):
    pass

engine = create_engine(DATABASE_URL)
SessionLocal = sessionmaker(bind=engine)
Base = declarative_base()


class TaskStatus(str, enum.Enum):
    todo = "todo"
    doing = "doing"
    done = "done"


class CsvExportStatus(str, enum.Enum):
    pending = "pending"
    complete = "complete"


class Task(Base):
    __tablename__ = "tasks"
    id = Column(Integer, primary_key=True)
    title = Column(String(255))
    description = Column(Text)
    status = Column(Enum(TaskStatus))
    picture_url = Column(String(1024))
    created_at = Column(DateTime, server_default=func.now())
    updated_at = Column(DateTime, server_default=func.now())


class CsvExport(Base):
    __tablename__ = "csv_exports"
    id = Column(Integer, primary_key=True)
    status = Column(Enum(CsvExportStatus))
    file_url = Column(String(1024))
    created_at = Column(DateTime, server_default=func.now())
    updated_at = Column(DateTime, server_default=func.now())


def process_csv_export(export_id: int):
    """CSV出力の処理"""
    db = SessionLocal()
    s3_client = boto3.client("s3", region_name=AWS_REGION)

    try:
        # タスク一覧を取得
        tasks = db.query(Task).all()

        # CSVを作成
        output = io.StringIO()
        writer = csv.writer(output)
        writer.writerow(["ID", "タイトル", "説明", "ステータス", "作成日時"])
        for task in tasks:
            writer.writerow([
                task.id,
                task.title,
                task.description or "",
                task.status,
                task.created_at
            ])

        # S3にアップロード
        key = f"csv_exports/{export_id}/tasks.csv"
        s3_client.put_object(
            Bucket=S3_BUCKET,
            Key=key,
            Body=output.getvalue().encode("utf-8-sig"),
            ContentType="text/csv"
        )

        # ステータスをcompleteに更新
        export = db.query(CsvExport).filter(CsvExport.id == export_id).first()
        if export:
            export.status = CsvExportStatus.complete
            export.file_url = key
            db.commit()

        print(f"CSV export {export_id} completed: {key}", flush=True)

    except Exception as e:
        print(f"Error processing CSV export {export_id}: {e}", flush=True)
        db.rollback()
    finally:
        db.close()


def main():
    """SQSからメッセージを受け取ってCSV出力を処理する"""
    sqs_client = boto3.client("sqs", region_name=AWS_REGION)
    print("Worker started. Waiting for messages...", flush=True)

    while True:
        try:
            # SQSからメッセージを取得
            response = sqs_client.receive_message(
                QueueUrl=SQS_QUEUE_URL,
                MaxNumberOfMessages=1,
                WaitTimeSeconds=20
            )

            messages = response.get("Messages", [])
            if not messages:
                continue

            for message in messages:
                body = json.loads(message["Body"])
                export_id = body.get("export_id")

                if export_id:
                    print(f"Processing CSV export: {export_id}", flush=True)
                    process_csv_export(export_id)

                # メッセージを削除
                sqs_client.delete_message(
                    QueueUrl=SQS_QUEUE_URL,
                    ReceiptHandle=message["ReceiptHandle"]
                )

        except Exception as e:
            print(f"Error: {e}", flush=True)
            time.sleep(5)


if __name__ == "__main__":
    main()