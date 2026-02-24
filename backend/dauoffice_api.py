import requests
import base64
from datetime import datetime, timedelta
from models import db, DauofficeToken

# SSL 경고 억제
import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)


class DauofficeAPIClient:
    """다우오피스 OpenAPI 클라이언트
    
    인증 방식: OAuth2 Client Credentials
    - POST /public/auth/v1/oauth2/token
    - Authorization: Basic Base64(clientId:clientSecret)
    - grant_type=client_credentials
    - 발급된 Access Token을 Bearer로 사용
    """
    
    TOKEN_ENDPOINT = "/public/auth/v1/oauth2/token"
    
    def __init__(self, client_id, client_secret, api_url="https://api.daouoffice.com"):
        self.client_id = client_id
        self.client_secret = client_secret
        self.api_url = api_url
        self.access_token = None
        self.token_expires_at = None
    
    @property
    def _basic_auth_header(self):
        """Basic Auth 헤더 생성: Base64(clientId:clientSecret)"""
        credentials = f"{self.client_id}:{self.client_secret}"
        encoded = base64.b64encode(credentials.encode('utf-8')).decode('utf-8')
        return f"Basic {encoded}"
    
    def get_access_token(self):
        """Access Token 발급/조회 (OAuth2 Client Credentials 방식)
        
        - DB에 유효한 토큰이 있으면 재사용
        - 없거나 만료되면 새로 발급
        """
        # 1) 메모리 캐시 확인
        if self.access_token and self.token_expires_at:
            if datetime.utcnow() < self.token_expires_at:
                return self.access_token
        
        # 2) DB 캐시 확인
        try:
            token_record = DauofficeToken.query.order_by(
                DauofficeToken.created_at.desc()
            ).first()
            if token_record and token_record.is_valid():
                self.access_token = token_record.access_token
                self.token_expires_at = token_record.expires_at
                print(f"[DauofficeAPI] DB 캐시 토큰 사용 (만료: {token_record.expires_at})")
                return self.access_token
        except Exception as e:
            print(f"[DauofficeAPI] DB 토큰 조회 오류: {e}")
        
        # 3) 새 토큰 발급
        return self._issue_new_token()
    
    def _issue_new_token(self):
        """다우오피스 OAuth2 토큰 발급"""
        url = f"{self.api_url}{self.TOKEN_ENDPOINT}"
        headers = {
            "Authorization": self._basic_auth_header,
            "Content-Type": "application/x-www-form-urlencoded"
        }
        data = "grant_type=client_credentials"
        
        print(f"[DauofficeAPI] Access Token 발급 요청: {url}")
        
        try:
            response = requests.post(
                url, data=data, headers=headers,
                verify=False, timeout=15
            )
            print(f"[DauofficeAPI] Token 발급 응답: {response.status_code}")
            
            if response.status_code == 200:
                result = response.json()
                self.access_token = result.get('access_token')
                expires_in = result.get('expires_in', 86400)  # 기본 24시간
                self.token_expires_at = datetime.utcnow() + timedelta(seconds=expires_in - 300)
                
                print(f"[DauofficeAPI] Access Token 발급 성공 (유효: {expires_in}초)")
                
                # DB에 저장
                try:
                    token_record = DauofficeToken(
                        access_token=self.access_token,
                        expires_at=self.token_expires_at
                    )
                    db.session.add(token_record)
                    db.session.commit()
                except Exception as e:
                    print(f"[DauofficeAPI] 토큰 DB 저장 오류: {e}")
                
                return self.access_token
            else:
                error = response.json() if response.content else {}
                print(f"[DauofficeAPI] Token 발급 실패: {response.status_code} - {error}")
                return None
        
        except requests.exceptions.ConnectionError as e:
            print(f"[DauofficeAPI] 연결 오류: {e}")
            return None
        except Exception as e:
            print(f"[DauofficeAPI] Token 발급 예외: {e}")
            return None
    
    def _make_request(self, method, endpoint, params=None, json_data=None, retry=True):
        """공통 API 요청 메서드 (토큰 만료 시 자동 재발급)"""
        token = self.get_access_token()
        if not token:
            print(f"[DauofficeAPI] Access Token이 없습니다.")
            return None
        
        url = f"{self.api_url}{endpoint}"
        headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json"
        }
        
        try:
            if method == "GET":
                response = requests.get(
                    url, headers=headers, params=params,
                    verify=False, timeout=15
                )
            elif method == "POST":
                response = requests.post(
                    url, headers=headers, json=json_data,
                    verify=False, timeout=15
                )
            else:
                return None
            
            # 401 토큰 만료 → 재발급 후 1회 재시도
            if response.status_code == 401 and retry:
                print(f"[DauofficeAPI] 401 응답 → 토큰 재발급 후 재시도")
                self.access_token = None
                self.token_expires_at = None
                self._issue_new_token()
                return self._make_request(method, endpoint, params, json_data, retry=False)
            
            return response
        
        except Exception as e:
            print(f"[DauofficeAPI] API 요청 오류 ({method} {endpoint}): {e}")
            return None
    
    # ==================== 조직 정보 API ====================
    
    def get_organization_info(self):
        """조직도 사용자 목록 조회 (v3)
        
        GET /public/api/attnd-v3/organization-chart/user/list
        
        Returns:
            list: 직원 정보 리스트
        """
        endpoint = "/public/api/attnd-v3/organization-chart/user/list"
        response = self._make_request("GET", endpoint)
        
        if response is None:
            print("[DauofficeAPI] 조직 정보 조회: 응답 없음")
            return []
        
        print(f"[DauofficeAPI] 조직 정보 응답: {response.status_code}")
        
        if response.status_code == 200:
            data = response.json()
            # 다우오피스 응답 code 필드는 정수 또는 문자열일 수 있음
            code = str(data.get('code', ''))
            if code == '200':
                employees = data.get('data', [])
                print(f"[DauofficeAPI] 직원 수: {len(employees)}")
                return employees
            else:
                print(f"[DauofficeAPI] 조직 정보 오류: {data.get('message')} / {data.get('messageDetail')}")
                return []
        else:
            print(f"[DauofficeAPI] 조직 정보 HTTP 오류: {response.status_code} - {response.text[:200]}")
            return []
    
    # ==================== 근태 정보 API ====================
    
    def get_attendance_records(self, start_date, end_date, page=0, page_size=50):
        """근태 이력 조회 (v2)
        
        GET /public/api/attnd-v2/attnd
        
        Args:
            start_date: 시작일 (YYYY-MM-DD)
            end_date: 종료일 (YYYY-MM-DD, 최대 31일 범위)
            page: 페이지 번호 (기본값: 0)
            page_size: 페이지 크기 (기본값: 50)
        
        Returns:
            dict: { totalCount, currentPage, pageSize, totalPages, elements }
        """
        endpoint = "/public/api/attnd-v2/attnd"
        params = {
            "startDate": start_date,
            "endDate": end_date,
            "page": page,
            "pageSize": page_size
        }
        
        response = self._make_request("GET", endpoint, params=params)
        
        if response is None:
            return {'totalCount': 0, 'elements': [], 'totalPages': 0}
        
        print(f"[DauofficeAPI] 근태 조회 응답: {response.status_code} (page={page})")
        
        if response.status_code == 200:
            data = response.json()
            code = str(data.get('code', ''))
            if code == '200':
                return data.get('data', {'totalCount': 0, 'elements': [], 'totalPages': 0})
            else:
                print(f"[DauofficeAPI] 근태 조회 오류: {data.get('message')}")
                return {'totalCount': 0, 'elements': [], 'totalPages': 0}
        else:
            print(f"[DauofficeAPI] 근태 조회 HTTP 오류: {response.status_code} - {response.text[:200]}")
            return {'totalCount': 0, 'elements': [], 'totalPages': 0}
    
    # ==================== 동기화 메서드 ====================
    
    def sync_employees_from_dauoffice(self):
        """다우오피스 → DB 직원 동기화
        
        Returns:
            int: 동기화된 직원 수
        """
        from models import Employee
        
        employees = self.get_organization_info()
        if not employees:
            print("[DauofficeAPI] 동기화할 직원 데이터가 없습니다.")
            return 0
        
        synced_count = 0
        
        for emp_data in employees:
            login_id = emp_data.get('loginId')
            
            # loginId가 없거나 비어있으면 부서 노드(진짜 직원 아님)
            if not login_id or not login_id.strip():
                continue
            
            # employeeNumber가 없으면 부서/그룹 노드일 가능성이 높음 — 건너뛴기
            if not emp_data.get('employeeNumber'):
                continue
            
            # 부서 정보 (userGroups 첫 번째)
            user_groups = emp_data.get('userGroups', [])
            department = user_groups[0].get('name') if user_groups else '미지정'
            name = emp_data.get('name', '이름없음')
            
            # 수동 입력된 직원 중 동일 이름이 있으면 dauoffice_user_id 업데이트
            manual_emp = Employee.query.filter_by(
                name=name, data_source='manual'
            ).first()
            if manual_emp and not manual_emp.dauoffice_user_id:
                manual_emp.dauoffice_user_id = login_id
                manual_emp.department = department
                manual_emp.data_source = 'dauoffice'
                synced_count += 1
                print(f"[DauofficeAPI] 수동입력 직원 연결: {name} ({department})")
                continue
            
            employee = Employee.query.filter_by(dauoffice_user_id=login_id).first()
            
            if not employee:
                employee = Employee(
                    name=name,
                    department=department,
                    data_source='dauoffice',
                    dauoffice_user_id=login_id,
                    is_active=True  # 신규 직원은 항상 활성
                )
                db.session.add(employee)
                print(f"[DauofficeAPI] 신규 직원 추가: {name} ({department})")
            else:
                employee.name = name
                employee.department = department
                # ⚠️ status(ONLINE/OFFLINE)는 접속상태이지 재직상태가 아님 → is_active 변경 안 함
                # expiredDate가 있을 경우에만 퇴직 처리 가능
                expired = emp_data.get('expiredDate', '')
                if expired and expired < datetime.utcnow().strftime('%Y-%m-%d'):
                    employee.is_active = False
                else:
                    employee.is_active = True  # 재직 중으로 유지
                print(f"[DauofficeAPI] 직원 업데이트: {name} ({department})")
            
            synced_count += 1
        
        db.session.commit()
        print(f"[DauofficeAPI] 직원 동기화 완료: {synced_count}명")
        return synced_count
    
    def sync_attendance_from_dauoffice(self, year, month):
        """다우오피스 → DB 근태 기록 동기화
        
        Args:
            year: 년도
            month: 월
        
        Returns:
            int: 동기화된 기록 수
        """
        from models import Employee, AttendanceRecord
        from calendar import monthrange
        
        _, last_day = monthrange(year, month)
        start_date = f"{year:04d}-{month:02d}-01"
        end_date = f"{year:04d}-{month:02d}-{last_day:02d}"
        
        print(f"[DauofficeAPI] 근태 동기화 시작: {start_date} ~ {end_date}")
        
        synced_count = 0
        page = 0
        page_size = 50
        
        while True:
            result = self.get_attendance_records(start_date, end_date, page, page_size)
            elements = result.get('elements', [])
            total_pages = result.get('totalPages', 1)
            total_count = result.get('totalCount', 0)
            
            print(f"[DauofficeAPI] 근태 페이지 {page+1}/{total_pages} ({len(elements)}건 / 전체 {total_count}건)")
            
            if not elements:
                break
            
            for att_data in elements:
                login_id = att_data.get('loginId')
                if not login_id:
                    continue
                
                employee = Employee.query.filter_by(dauoffice_user_id=login_id).first()
                if not employee:
                    continue
                
                accrual_date = att_data.get('accrualDate')
                if not accrual_date:
                    continue
                
                try:
                    date_obj = datetime.strptime(accrual_date, '%Y-%m-%d').date()
                except ValueError:
                    continue
                
                # 출근 시간 파싱
                start_work_time = att_data.get('startWorkTime')
                check_in_time = None
                if start_work_time:
                    try:
                        check_in_time = datetime.strptime(start_work_time, '%H:%M:%S').time()
                    except ValueError:
                        pass
                
                record_type = 'normal'
                
                existing = AttendanceRecord.query.filter_by(
                    employee_id=employee.id,
                    date=date_obj
                ).first()
                
                if not existing:
                    new_record = AttendanceRecord(
                        employee_id=employee.id,
                        date=date_obj,
                        check_in_time=check_in_time,
                        record_type=record_type,
                        data_source='dauoffice'
                    )
                    db.session.add(new_record)
                    synced_count += 1
                elif existing.data_source == 'dauoffice':
                    existing.check_in_time = check_in_time
                    existing.record_type = record_type
                    synced_count += 1
            
            page += 1
            if page >= total_pages:
                break
        
        db.session.commit()
        print(f"[DauofficeAPI] 근태 동기화 완료: {synced_count}건")
        return synced_count
