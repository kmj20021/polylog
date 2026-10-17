"""DynamoDB Local 테이블 7종을 만든다(이미 있으면 건너뜀).

키 구조는 docs/session_readme.md 의 테이블 표(ADR-014·015)와 같다.
docker compose 가 api 서버보다 먼저 1회 실행한다.
"""
import boto3

# (테이블, PK, SK) — SK 가 None 이면 PK 만 있는 테이블.
TABLES = [
    ("polylog-users", "user_id", None),
    ("polylog-trips", "trip_id", None),
    ("polylog-recommendations", "trip_id", "created_at"),
    ("polylog-menus", "trip_id", "created_at"),
    ("polylog-receipts", "trip_id", "occurred_at"),
    ("polylog-schedules", "trip_id", "start_time"),
    ("polylog-chats", "trip_id", "created_at"),
]

ddb = boto3.client("dynamodb", region_name="ap-northeast-2")
existing = set(ddb.list_tables()["TableNames"])
for name, pk, sk in TABLES:
    if name in existing:
        print(f"skip  {name}")
        continue
    keys = [(pk, "HASH")] + ([(sk, "RANGE")] if sk else [])
    ddb.create_table(
        TableName=name,
        AttributeDefinitions=[{"AttributeName": k, "AttributeType": "S"} for k, _ in keys],
        KeySchema=[{"AttributeName": k, "KeyType": t} for k, t in keys],
        BillingMode="PAY_PER_REQUEST",
    )
    print(f"made  {name}")

