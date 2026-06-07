"""fn-authorizer — API Gateway Lambda Authorizer (Google ID 토큰 검증).

TOKEN 타입 Authorizer.
  API Gateway 가 Authorization 헤더에서 Bearer 토큰을 꺼내 authorizationToken 으로 전달.
  Google tokeninfo 엔드포인트로 서명·만료·aud·iss 를 검증한 뒤 Allow 또는 Unauthorized 예외.

예외를 던지면 API GW 가 401 을 반환(Deny 정책은 403 — 용도가 다름).
"""

import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

GOOGLE_CLIENT_ID = os.environ.get("GOOGLE_CLIENT_ID", "")
_TOKENINFO_BASE = "https://oauth2.googleapis.com/tokeninfo"


def lambda_handler(event, context):
    token = _extract_token(event)
    if not token:
        raise Exception("Unauthorized")

    claims = _verify(token)
    if not claims:
        raise Exception("Unauthorized")

    return _policy(claims["sub"], "Allow", event.get("methodArn", "*"))


def _extract_token(event):
    """Authorization: Bearer <token> 에서 토큰 문자열 반환. 없으면 None."""
    raw = event.get("authorizationToken", "")
    return raw[7:] if raw.startswith("Bearer ") else None


def _verify(token):
    """Google tokeninfo 엔드포인트 호출 → 클레임 dict 반환. 유효하지 않으면 None.

    tokeninfo 는 Google 이 서버 측에서 서명을 검증해 주므로 cryptography 패키지 불필요.
    (JWKS 직접 검증 대비 ~100ms 추가 지연 — PoC 수준에서 허용)
    """
    url = _TOKENINFO_BASE + "?" + urllib.parse.urlencode({"id_token": token})
    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            claims = json.loads(resp.read().decode())
    except urllib.error.HTTPError:
        return None  # 400 = 토큰 무효
    except Exception:
        return None

    # aud — 이 앱의 클라이언트 ID 와 일치해야 함(env 미설정 시 검증 생략)
    if GOOGLE_CLIENT_ID and claims.get("aud") != GOOGLE_CLIENT_ID:
        return None

    # iss — Google 발급 토큰
    if claims.get("iss") not in ("accounts.google.com", "https://accounts.google.com"):
        return None

    # exp — 만료 확인
    try:
        if int(claims.get("exp", 0)) < int(time.time()):
            return None
    except (TypeError, ValueError):
        return None

    return claims


def _policy(principal_id, effect, resource):
    return {
        "principalId": principal_id,
        "policyDocument": {
            "Version": "2012-10-17",
            "Statement": [
                {"Action": "execute-api:Invoke", "Effect": effect, "Resource": resource}
            ],
        },
    }
