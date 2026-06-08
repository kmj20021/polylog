"""fn-authorizer 순수 로직 단위 테스트 (AWS·네트워크 불필요).

실행: cd backend && python -m pytest src/handlers/authorizer/ -q
tokeninfo 호출(`_fetch_tokeninfo`)은 monkeypatch 로 모킹한다.
"""
import pytest

import app


def _claims(**over):
    """유효한 Google 토큰 클레임 기본형 + 덮어쓰기."""
    base = {
        "sub": "google-sub-123",
        "iss": "https://accounts.google.com",
        "aud": "web-client-id",
        "email": "trav@example.com",
    }
    base.update(over)
    return base


def _event(token):
    return {
        "authorizationToken": token,
        "methodArn": "arn:aws:execute-api:ap-northeast-2:123:abcd/dev/GET/menu",
    }


# ── Bearer 파싱 ──────────────────────────────────────────────
def test_bearer_strips_prefix():
    assert app._bearer("Bearer abc.def.ghi") == "abc.def.ghi"
    assert app._bearer("bearer abc") == "abc"        # 대소문자 무시
    assert app._bearer("rawtoken") == "rawtoken"     # 접두사 없으면 그대로
    assert app._bearer("") == ""
    assert app._bearer(None) == ""


# ── 정책 스코프 와일드카드 ───────────────────────────────────
def test_scope_wildcards_to_stage():
    arn = "arn:aws:execute-api:ap-northeast-2:123:abcd/dev/GET/menu"
    assert app._scope(arn) == "arn:aws:execute-api:ap-northeast-2:123:abcd/dev/*/*"


# ── 토큰 없음 → 거부 ─────────────────────────────────────────
def test_no_token_unauthorized():
    with pytest.raises(Exception, match="Unauthorized"):
        app.lambda_handler(_event(""), None)


# ── 정상 토큰 → Allow + context.user_id ──────────────────────
def test_valid_token_allows(monkeypatch):
    monkeypatch.setattr(app, "_CLIENT_ID", "web-client-id")
    monkeypatch.setattr(app, "_fetch_tokeninfo", lambda t: _claims())
    res = app.lambda_handler(_event("Bearer good.jwt"), None)
    assert res["principalId"] == "google-sub-123"
    stmt = res["policyDocument"]["Statement"][0]
    assert stmt["Effect"] == "Allow"
    assert res["context"]["user_id"] == "google-sub-123"
    assert res["context"]["email"] == "trav@example.com"


# ── aud 불일치(다른 앱 토큰) → 거부 ──────────────────────────
def test_wrong_aud_unauthorized(monkeypatch):
    monkeypatch.setattr(app, "_CLIENT_ID", "web-client-id")
    monkeypatch.setattr(app, "_fetch_tokeninfo", lambda t: _claims(aud="someone-else"))
    with pytest.raises(Exception, match="Unauthorized"):
        app.lambda_handler(_event("Bearer x"), None)


# ── iss 불일치 → 거부 ────────────────────────────────────────
def test_wrong_iss_unauthorized(monkeypatch):
    monkeypatch.setattr(app, "_CLIENT_ID", "web-client-id")
    monkeypatch.setattr(app, "_fetch_tokeninfo", lambda t: _claims(iss="evil.com"))
    with pytest.raises(Exception, match="Unauthorized"):
        app.lambda_handler(_event("Bearer x"), None)


# ── 만료/위조(tokeninfo 가 예외) → 거부 ──────────────────────
def test_expired_token_unauthorized(monkeypatch):
    def boom(_):
        raise app.urllib.error.HTTPError("u", 400, "bad", {}, None)
    monkeypatch.setattr(app, "_fetch_tokeninfo", boom)
    with pytest.raises(Exception, match="Unauthorized"):
        app.lambda_handler(_event("Bearer expired"), None)


# ── GOOGLE_CLIENT_ID 미설정 → aud 검증 생략(sub/iss 만으로 통과) ──
def test_no_client_id_skips_aud(monkeypatch):
    monkeypatch.setattr(app, "_CLIENT_ID", "")
    monkeypatch.setattr(app, "_fetch_tokeninfo", lambda t: _claims(aud="anything"))
    res = app.lambda_handler(_event("Bearer x"), None)
    assert res["policyDocument"]["Statement"][0]["Effect"] == "Allow"
