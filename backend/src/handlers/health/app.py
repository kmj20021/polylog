"""fn-health — 배포 파이프라인 검증용 헬스체크.

비즈니스 로직 없음. 200 + JSON 반환만으로 'SAM 빌드→배포→API Gateway→Lambda'
경로가 살아있음을 증명한다(Phase 3 Exit 기준).
"""
import json


def lambda_handler(event, context):
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"status": "ok", "service": "polylog"}),
    }
