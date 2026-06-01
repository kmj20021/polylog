# Polylog DynamoDB 부트스트랩 명령 (Phase 2.3)
#
# [변경 이력]
# 2026-05-31  bootstrap-plan.md와 실제 생성 결과 정합성 검토
#   - polylog-trips 누락 확인 → #7로 추가 (다른 6개 테이블의 부모 entity, 모든 도메인의 trip_id 발급원)
#   - polylog-receipts (= plan의 expenses) 현 이름 유지
#   - polylog-chats   (= plan의 chatmessages) 현 이름 유지
#   - 위 명칭 변경은 polylog-plan.md 데이터 모델 섹션에 후속 반영 필요
#
# 2026-05-31 (오후)  schedule 테이블 단일화 결정 — ADR-014
#   - polylog-schedule-items 분리는 액세스 패턴(타임라인 뷰)에 부적합 → 삭제
#   - polylog-schedules 재설계: PK=schedule_id (standalone) → PK=trip_id + SK=start_time (composite)
#   - 사유: FR-S3.4(타임라인) / FR-S3.5(컨텍스트 재추천)가 "trip 단위 일괄 조회" 패턴
#   - 적용 절차: 기존 두 테이블 delete-table 후 아래 #2 명령으로 재생성 (데이터 0건이라 손실 無)
#
# 2026-05-31 (저녁)  도메인 4종 테이블 키 통일 — ADR-015
#   - recommendations / menus / receipts / chats 모두 PK=standalone-UUID → trip_id 합성키로 재설계
#   - 사유: 각 도메인 액세스 패턴이 "여행 단위 시간순 조회"로 동일 (FR-M.6 / FR-S1 / FR-S2.4 / FR-S3.1)
#       · recommendations  SK=created_at     (추천 누적 이력)
#       · menus            SK=created_at     (촬영 시점 정렬)
#       · receipts         SK=occurred_at    (결제 시각 = "일별 지출" 정렬)
#       · chats            SK=created_at     (Bedrock 컨텍스트 시간순 로드)
#   - 적용 절차: 기존 4개 delete-table 후 아래 #3~#6 명령으로 재생성 (데이터 0건이라 손실 無)

# 1. 회원 정보 서랍장
aws dynamodb create-table \
    --table-name polylog-users \
    --attribute-definitions AttributeName=user_id,AttributeType=S \
    --key-schema AttributeName=user_id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region ap-northeast-2

# 2. 여행 일정 서랍장 (단일 테이블 — schedule-items 통합, ADR-014)
#    PK=trip_id, SK=start_time(ISO 8601) → 타임라인 뷰는 Query PK=trip_id 한 번
#    재생성 전 기존 두 테이블 삭제 필수:
#       aws dynamodb delete-table --table-name polylog-schedules      --region ap-northeast-2
#       aws dynamodb delete-table --table-name polylog-schedule-items --region ap-northeast-2
aws dynamodb create-table \
    --table-name polylog-schedules \
    --attribute-definitions \
        AttributeName=trip_id,AttributeType=S \
        AttributeName=start_time,AttributeType=S \
    --key-schema \
        AttributeName=trip_id,KeyType=HASH \
        AttributeName=start_time,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST \
    --region ap-northeast-2

# 3. 가계부/영수증 서랍장 (ADR-015)
#    PK=trip_id, SK=occurred_at(ISO 8601, 결제 시각) → "일별·카테고리별 지출"(FR-S2.4)이 시간순 정렬로 충족
#    receipt_id(UUID)는 일반 속성으로 강등 — 단건 외부 참조용
#    재생성 전 기존 테이블 삭제 필수:
#       aws dynamodb delete-table --table-name polylog-receipts --region ap-northeast-2
aws dynamodb create-table \
    --table-name polylog-receipts \
    --attribute-definitions \
        AttributeName=trip_id,AttributeType=S \
        AttributeName=occurred_at,AttributeType=S \
    --key-schema \
        AttributeName=trip_id,KeyType=HASH \
        AttributeName=occurred_at,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST \
    --region ap-northeast-2

# 4. 맛집/메뉴판 서랍장 (ADR-015)
#    PK=trip_id, SK=created_at(ISO 8601, 촬영 시점) → 여행 중 분석한 메뉴판 이력 시간순 조회
#    menu_id(UUID)는 일반 속성으로 강등
#    재생성 전 기존 테이블 삭제 필수:
#       aws dynamodb delete-table --table-name polylog-menus --region ap-northeast-2
aws dynamodb create-table \
    --table-name polylog-menus \
    --attribute-definitions \
        AttributeName=trip_id,AttributeType=S \
        AttributeName=created_at,AttributeType=S \
    --key-schema \
        AttributeName=trip_id,KeyType=HASH \
        AttributeName=created_at,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST \
    --region ap-northeast-2

# 5. AI 추천 장소 보관함 (ADR-015)
#    PK=trip_id, SK=created_at(ISO 8601) → 한 여행의 추천 이력 누적·시간순 조회(FR-M.6)
#    recommendation_id(UUID)는 일반 속성으로 강등
#    재생성 전 기존 테이블 삭제 필수:
#       aws dynamodb delete-table --table-name polylog-recommendations --region ap-northeast-2
aws dynamodb create-table \
    --table-name polylog-recommendations \
    --attribute-definitions \
        AttributeName=trip_id,AttributeType=S \
        AttributeName=created_at,AttributeType=S \
    --key-schema \
        AttributeName=trip_id,KeyType=HASH \
        AttributeName=created_at,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST \
    --region ap-northeast-2

# 6. 채팅방 서랍장 (ChatMessage 의미, ADR-015)
#    PK=trip_id, SK=created_at(ISO 8601) → Bedrock 호출 직전 Query 한 번으로 대화 컨텍스트 일괄 로드
#    message_id(UUID)는 일반 속성 — 일정-메시지 역추적은 schedule.chat_message_id 단방향으로 충분
#    재생성 전 기존 테이블 삭제 필수:
#       aws dynamodb delete-table --table-name polylog-chats --region ap-northeast-2
aws dynamodb create-table \
    --table-name polylog-chats \
    --attribute-definitions \
        AttributeName=trip_id,AttributeType=S \
        AttributeName=created_at,AttributeType=S \
    --key-schema \
        AttributeName=trip_id,KeyType=HASH \
        AttributeName=created_at,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST \
    --region ap-northeast-2

# 7. 여행 서랍장 (부모 entity — 다른 6개 테이블이 trip_id를 외래키처럼 참조)
#    GSI(user_id-index): "내 여행 목록을 최신순으로" 조회용 (메인 화면 진입 패턴)
aws dynamodb create-table \
    --table-name polylog-trips \
    --attribute-definitions \
        AttributeName=trip_id,AttributeType=S \
        AttributeName=user_id,AttributeType=S \
        AttributeName=start_date,AttributeType=S \
    --key-schema AttributeName=trip_id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --global-secondary-indexes '[{
        "IndexName":"user_id-index",
        "KeySchema":[
          {"AttributeName":"user_id","KeyType":"HASH"},
          {"AttributeName":"start_date","KeyType":"RANGE"}
        ],
        "Projection":{"ProjectionType":"ALL"}
    }]' \
    --region ap-northeast-2
