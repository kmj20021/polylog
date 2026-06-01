"""fn-authorizer — API Gateway Lambda Authorizer (골격, deny-all).

현재는 모든 요청을 거부한다. 실제 검증 로직은 Phase 4에서 구현(ADR-007).
provider 범위는 Google 단독으로 확정됨(ADR-007 2026-06-01) — Kakao 보류.

이 함수는 template.yaml에 아직 연결되어 있지 않다(Phase 3는 Authorizer NONE).
파일만 먼저 두어 Phase 4에서 코드만 채우면 되도록 한다.
"""


def lambda_handler(event, context):
    # TODO(Phase 4): Google ID 토큰 검증
    #   1) JWKS 조회: https://www.googleapis.com/oauth2/v3/certs
    #   2) iss ∈ {accounts.google.com, https://accounts.google.com}
    #   3) aud == <Google Android OAuth 클라이언트 ID>  (환경변수로 주입)
    #   4) exp 유효 → principalId = 토큰의 sub, Effect=Allow
    return _policy("anonymous", "Deny", event.get("methodArn", "*"))


def _policy(principal_id, effect, resource):
    return {
        "principalId": principal_id,
        "policyDocument": {
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Action": "execute-api:Invoke",
                    "Effect": effect,
                    "Resource": resource,
                }
            ],
        },
    }
