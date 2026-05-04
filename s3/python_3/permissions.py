import boto3
import json
from pathlib import Path

S3API = boto3.client("s3", region_name="us-east-1")
bucket_name = "static-website-2026-05-02"

policy_path = Path(__file__).resolve().parents[1] / "website_security_policy.json"
with policy_path.open("r", encoding="utf-8") as policy_file:
    policy_text = policy_file.read()

try:
    S3API.put_bucket_policy(
        Bucket=bucket_name,
        Policy=policy_text
    )
    print("DONE")
except Exception as e:
    print("ERROR applying bucket policy:", e)
