"""polylog 로컬 서버 — API Gateway + Lambda 를 대신하는 얇은 어댑터.

HTTP 요청을 API Gateway(REST, 프록시) 이벤트 모양으로 바꿔 기존 핸들러의
lambda_handler 를 그대로 호출한다. 핸들러 코드는 수정하지 않는다.
인증은 AWS 와 같게 fn-authorizer 를 먼저 호출하고(/health·OPTIONS 제외),
통과하면 그 context 를 requestContext.authorizer 에 심는다.
"""
import importlib.util
import os
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response

_HANDLERS_DIR = Path(os.environ.get("HANDLERS_DIR", "/app/handlers"))
_AUTH_ENABLED = os.environ.get("AUTH_ENABLED", "true").lower() == "true"


# 핸들러 폴더마다 파일명이 app.py 로 같아서 모듈 이름을 따로 붙여 불러온다.
def _load(name):
    spec = importlib.util.spec_from_file_location(f"handler_{name}", _HANDLERS_DIR / name / "app.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.lambda_handler


# template.yaml 의 라우트와 동일(/menu 는 앱이 안 불러서 제외 — ADR-018).
_ROUTES = {
    ("GET", "/health"): _load("health"),
    ("POST", "/recommend"): _load("recommend"),
    ("GET", "/schedule"): _load("schedule"),
    ("POST", "/schedule"): _load("schedule"),
    ("POST", "/planner"): _load("planner"),
    ("POST", "/receipt"): _load("receipt"),
}
_authorizer = _load("authorizer")

app = FastAPI()


# 핸들러를 Lambda context 없이 호출해도 되도록 최소한의 더미를 넘긴다.
class _Ctx:
    function_name = "polylog-local"
    aws_request_id = "local"

    def get_remaining_time_in_millis(self):
        return 30000


@app.api_route("/{path:path}", methods=["GET", "POST", "DELETE", "OPTIONS"])
async def dispatch(path: str, request: Request):
    method = request.method
    route = "/" + path.strip("/")

    # CORS preflight — API Gateway 처럼 핸들러까지 가지 않고 바로 응답.
    if method == "OPTIONS":
        return Response(status_code=200, headers={
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Content-Type,Authorization",
            "Access-Control-Allow-Methods": "GET,POST,DELETE,OPTIONS",
        })

    handler = _ROUTES.get((method, route))
    if handler is None:
        return JSONResponse({"message": "Missing Authentication Token"}, status_code=403)

    authz = {}
    if _AUTH_ENABLED and route != "/health":
        try:
            result = _authorizer({
                "authorizationToken": request.headers.get("authorization", ""),
                "methodArn": f"local/dev/{method}{route}",
            }, _Ctx())
            authz = result.get("context") or {}
        except Exception:
            return JSONResponse({"message": "Unauthorized"}, status_code=401)

    body = (await request.body()).decode("utf-8") or None
    event = {
        "httpMethod": method,
        "path": route,
        "resource": route,
        "headers": dict(request.headers),
        "queryStringParameters": dict(request.query_params) or None,
        "body": body,
        "isBase64Encoded": False,
        "requestContext": {"authorizer": authz},
    }
    out = handler(event, _Ctx())
    return Response(
        content=out.get("body") or "",
        status_code=out.get("statusCode", 200),
        headers=out.get("headers") or {},
    )
