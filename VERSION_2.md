# AMS 작업 이력 - Ver 2

## 2026-03-02 작업 내용

### 1. ngrok 업그레이드 및 설정 수정
- **ngrok v3.3.1 → v3.36.1** 업그레이드 (인증 최소 버전 충족)
- NGROK_DOMAIN: `.app` → `.dev` 도메인 수정
- SENSELINK_URL: `175.198.93.89:8765` → `localhost:8765` 변경
- 배치 파일 위치: `C:\AMS\start_ngrok_relay.bat`

### 2. relay_server.py v8 개발 및 배포
- 파일 위치: `D:\26년 유지보수 개발계획안\출근기록개발\relay_server.py`
- MySQL 직접 연동 (SenseLink HTTP API 불안정 문제 우회)
- `start`/`end` 파라미터 지원 추가 (AMS app.py와 호환)
- `dateTimeFrom`/`dateTimeTo` 파라미터 병행 지원
- 버그 수정: `dept or ALL` → `dept or 'ALL'` (NameError 해결)
- 사용 패키지: Flask 3.1.3, PyMySQL 1.1.2, requests

### 3. 아키텍처 변경
```
[이전] AWS EC2 → ngrok → 175.198.93.89:8765 (SenseLink HTTP API, 불안정)
[이후] AWS EC2 → ngrok → localhost:8765 (relay_server.py) → MySQL 192.168.250.183
```

### 4. Windows 자동 시작 등록
- `AMS_relay_server`: 로그인 시 relay_server.py 자동 실행
  - Python: `C:\Users\hp\AppData\Local\Programs\Python\Python311-32\python.exe`
  - 스크립트: `D:\26년 유지보수 개발계획안\출근기록개발\relay_server.py`
- `AMS_ngrok_relay`: 로그인 시 ngrok 자동 실행
  - 배치: `C:\AMS\start_ngrok_relay.bat`

### 5. 검증 결과
| 항목 | 결과 |
|------|------|
| MySQL 연결 | ✅ 연결 성공 (192.168.250.183:3306) |
| /health | ✅ db:connected, total:109,815, feb:7,559, mar:5 |
| /attendance (2월) | ✅ total 7,559건 정상 반환 |
| AWS sync (2월) | ✅ fetched:7,559, synced:967, errors:0 |
| ngrok 터널 | ✅ https://luke-subfestive-phyliss.ngrok-free.dev |
| 자동 시작 | ✅ 스케줄러 등록 완료 |

### 6. SenseLink DB 정보
| 구분 | 값 |
|------|-----|
| MySQL IP | 192.168.250.183 |
| Port | 3306 |
| User | senselink |
| Password | senselink_2018_local |
| Database | bi_slink_base |
| 주요 테이블 | t_record (출퇴근 기록) |

### 7. ngrok 정보
| 구분 | 값 |
|------|-----|
| 버전 | 3.36.1 |
| 계정 | aikms.htkim5505@gmail.com |
| 플랜 | Free |
| Static Domain | luke-subfestive-phyliss.ngrok-free.dev |
| Region | Japan |
| 포워딩 | https://... → http://localhost:8765 |
