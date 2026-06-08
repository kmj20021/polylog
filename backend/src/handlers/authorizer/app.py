"""fn-authorizer — API Gateway Lambda Authorizer (Google OAuth ID 토큰 검증).

ADR-007(Google 단독·Android): 클라이언트가 google_sign_in 으로 받은 ID 토큰을
`Authorization: Bearer <JWT>` 헤더로 보내면, 이 함수가 검증해 Allow/Deny 정책을 돌려준다.
통과 시 `context.user_id` 에 토큰의 sub(= 우리 user_id)를 실어 핸들러로 전달한다.

검증 방식(최소·의존성 0): Google 의 **tokeninfo** 엔드포인트에 위임한다.
  GET https://oauth2.googleapis.com/tokeninfo?id_token=<JWT>
구글이 서명·만료를 검증해 클레임(JSON)을 돌려준다(만료/위조면 HTTP 400). 우리는 추가로
`aud`(= GOOGLE_CLIENT_ID)·`iss` 만 확인한다. urllib 만 쓰므로(PyJWT·cryptography 번들 불필요)
공용 역할 **SafeRole-polylog** 권한만으로 동작하고, 외부 호출은 tokeninfo 1회뿐이다.
(RS256 로컬 JWKS 검증은 외부 라이브러리가 필요해 PoC 에선 tokeninfo 로 단일화 — ADR-007 보강.)

env: `GOOGLE_CLIENT_ID`(= 웹 클라이언트 ID, ID 토큰의 aud). 미설정이면 aud 검증을 생략한다.
타입: API Gateway **TOKEN** authorizer
  event.authorizationToken = "Bearer <JWT>", event.methodArn = 호출된 메서드 ARN.
"""
import json
import os
import urllib.error
import urllib.parse
import urllib.request

_CLIENT_ID = os.environ.get("GOOGLE_CLIENT_ID", "").strip()
_TOKENINFO = "https://oauth2.googleapis.com/tokeninfo?id_token="
_VALID_ISS = {"accounts.google.com", "https://accounts.google.com"}


def lambda_handler(event, context):
    token = _bearer(event.get("authorizationToken") or "")
    claims = _verify(token)
    if not claims:
        # 토큰 없음/위조/만료 → API Gateway 가 정확히 'Unauthorized' 를 401 로 변환한다.
        raise Exception("Unauthorized")
    return _allow(claims["sub"], event.get("methodArn", "*"), claims)


def _bearer(header):
    """'Bearer xxx' → 'xxx'. 접두사가 없으면 값 그대로, 비어 있으면 ''."""
    h = (header or "").strip()
    if not h:
        return ""
    if h.lower().startswith("bearer "):
        return h[7:].strip()
    return h


def _fetch_tokeninfo(token):
    """tokeninfo 엔드포인트 호출 → 클레임 dict. (테스트에서 monkeypatch 하는 AWS/네트워크 경계.)"""
    url = _TOKENINFO + urllib.parse.quote(token, safe="")
    with urllib.request.urlopen(url, timeout=4) as r:
        return json.loads(r.read())


def _verify(token):
    """토큰을 검증하고 클레임 dict 를 반환. 실패하면 None(거부)."""
    if not token:
        return None
    try:
        data = _fetch_tokeninfo(token)
    except (urllib.error.HTTPError, urllib.error.URLError, ValueError, TimeoutError):
        return None  # 400=만료/위조, 네트워크 오류 등 → 보수적으로 거부
    except Exception:
        return None
    if not isinstance(data, dict) or not data.get("sub"):
        return None
    if data.get("iss") not in _VALID_ISS:
        return None
    # 웹 클라이언트 ID 가 설정돼 있으면 aud 일치까지 확인(다른 앱의 토큰 차단).
    if _CLIENT_ID and data.get("aud") != _CLIENT_ID:
        return None
    return data


def _allow(sub, method_arn, claims):
    """통과 정책 — 같은 API·스테이지 전체에 Allow + context 에 user_id/email 전달."""
    return {
        "principalId": sub,
        "policyDocument": {
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Action": "execute-api:Invoke",
                    "Effect": "Allow",
                    "Resource": _scope(method_arn),
                }
            ],
        },
        # context 값은 문자열/숫자/불리언만 허용 → 핸들러는
        # event["requestContext"]["authorizer"]["user_id"] 로 읽는다.
        "context": {
            "user_id": str(sub),
            "email": str(claims.get("email") or ""),
        },
    }


def _scope(method_arn):
    """정책을 같은 API·스테이지의 모든 메서드/경로에 적용(authorizer 결과 캐시 재사용).

    methodArn 예: arn:aws:execute-api:REGION:ACCT:apiId/dev/GET/menu
    →           arn:aws:execute-api:REGION:ACCT:apiId/dev/*/*
    """
    parts = method_arn.split("/")
    if len(parts) >= 2:
        return f"{parts[0]}/{parts[1]}/*/*"
    return method_arn
