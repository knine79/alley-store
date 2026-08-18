#!/bin/sh
# 테스트 전용 데이터베이스를 만든다.
#
# postgres 이미지는 데이터 디렉터리가 비어 있을 때만 이 디렉터리의 스크립트를 돌린다.
# 이미 볼륨이 있는 환경에서는 실행되지 않으므로, 그 경우에는 README 의 안내대로
# 손으로 한 번 만들어야 한다.
#
# 테스트는 끝날 때마다 스키마를 통째로 되돌린다. 개발용 데이터베이스를 그대로 쓰면
# 개발 중이던 데이터가 날아간다.
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
	CREATE DATABASE ${POSTGRES_DB}_test OWNER $POSTGRES_USER;
EOSQL

echo "테스트 데이터베이스 준비 완료: ${POSTGRES_DB}_test"
