# polylog API 서버 이미지 — Lambda 핸들러를 FastAPI 어댑터로 감싸 실행.
# 빌드 컨텍스트는 저장소 루트(docker-compose.yml 위치).
FROM python:3.12-slim

WORKDIR /app
RUN pip install --no-cache-dir boto3==1.35.36 fastapi==0.115.0 uvicorn==0.30.6

COPY backend/src/handlers/ /app/handlers/
COPY docker/server.py /app/server.py

EXPOSE 8000
CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8000"]
