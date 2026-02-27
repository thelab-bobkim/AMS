
import requests

import base64

from datetime import datetime, timedelta

from models import db, DauofficeToken



import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)





def _extract_department(emp_data):
    """
    DauOffice userGroups에서 실제 부서명을 추출한다.
    우선순위:
      1) group.get('type') in ('DEPT','dept','department','organization') -> name
      2) 한국어 + 부서 키워드(본부/팀/부/실/센터/그룹/사업부/담당) 포함
      3) 한국어 문자 포함
      4) 첫 번째 그룹 name (fallback)
    """
    import re as _re
    DEPT_KEYWORDS = ['본부', '팀', '부', '실', '센터', '그룹', '사업부', '담당', '사업', '부문']
    DEPT_TYPES    = {'dept', 'department', 'organization', 'org'}
    user_groups = emp_data.get('userGroups', [])

    # 1순위: group type 이 dept/organization 인 그룹
    for g in user_groups:
        gtype = str(g.get('type', '')).lower()
        if gtype in DEPT_TYPES:
            name = g.get('name', '').strip()
            if name:
                return name

    # 2순위: 한국어 + 부서 키워드
    for g in user_groups:
        name = g.get('name', '').strip()
        if _re.search(r'[가-힣]', name) and any(kw in name for kw in DEPT_KEYWORDS):
            return name

    # 3순위: 한국어 포함
    for g in user_groups:
        name = g.get('name', '').strip()
        if _re.search(r'[가-힣]', name):
            return name

    # 4순위: 첫 번째 그룹 (fallback)
    if user_groups:
        return user_groups[0].get('name', '').strip()

    return ''


class DauofficeAPIClient:

    TOKEN_ENDPOINT = "/public/auth/v1/oauth2/token"

    

    def __init__(self, client_id, client_secret, api_url="https://api.daouoffice.com"):

        self.client_id = client_id

        self.client_secret = client_secret

        self.api_url = api_url

        self.access_token = None

        self.token_expires_at = None

    

    @property

    def _basic_auth_header(self):

        credentials = f"{self.client_id}:{self.client_secret}"

        encoded = base64.b64encode(credentials.encode('utf-8')).decode('utf-8')

        return f"Basic {encoded}"

    

    def get_access_token(self):

        if self.access_token and self.token_expires_at:

            if datetime.utcnow() < self.token_expires_at:

                return self.access_token

        try:

            token_record = DauofficeToken.query.order_by(DauofficeToken.created_at.desc()).first()

            if token_record and token_record.is_valid():

                self.access_token = token_record.access_token

                self.token_expires_at = token_record.expires_at

                print(f"[DauofficeAPI] DB 캐시 토큰 사용 (만료: {token_record.expires_at})")

                return self.access_token

        except Exception as e:

            print(f"[DauofficeAPI] DB 토큰 조회 오류: {e}")

        return self._issue_new_token()

    

    def _issue_new_token(self):

        url = f"{self.api_url}{self.TOKEN_ENDPOINT}"

        headers = {"Authorization": self._basic_auth_header, "Content-Type": "application/x-www-form-urlencoded"}

        data = "grant_type=client_credentials"

        print(f"[DauofficeAPI] Access Token 발급 요청: {url}")

        try:

            response = requests.post(url, data=data, headers=headers, verify=False, timeout=15)

            print(f"[DauofficeAPI] Token 발급 응답: {response.status_code}")

            if response.status_code == 200:

                result = response.json()

                self.access_token = result.get('access_token')

                expires_in = result.get('expires_in', 86400)

                self.token_expires_at = datetime.utcnow() + timedelta(seconds=expires_in - 300)

                print(f"[DauofficeAPI] Access Token 발급 성공 (유효: {expires_in}초)")

                try:

                    token_record = DauofficeToken(access_token=self.access_token, expires_at=self.token_expires_at)

                    db.session.add(token_record)

                    db.session.commit()

                except Exception as e:

                    print(f"[DauofficeAPI] 토큰 DB 저장 오류: {e}")

                return self.access_token

            else:

                print(f"[DauofficeAPI] Token 발급 실패: {response.status_code}")

                return None

        except Exception as e:

            print(f"[DauofficeAPI] Token 발급 예외: {e}")

            return None

    

    def _make_request(self, method, endpoint, params=None, json_data=None, retry=True):

        token = self.get_access_token()

        if not token:

            return None

        url = f"{self.api_url}{endpoint}"

        headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

        try:

            if method == "GET":

                response = requests.get(url, headers=headers, params=params, verify=False, timeout=15)

            elif method == "POST":

                response = requests.post(url, headers=headers, json=json_data, verify=False, timeout=15)

            else:

                return None

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



    def get_organization_info(self):

        endpoint = "/public/api/attnd-v3/organization-chart/user/list"

        response = self._make_request("GET", endpoint)

        if response is None:

            return []

        print(f"[DauofficeAPI] 조직 정보 응답: {response.status_code}")

        if response.status_code == 200:

            data = response.json()

            code = str(data.get('code', ''))

            if code == '200':

                employees = data.get('data', [])

                print(f"[DauofficeAPI] 전체 계정 수: {len(employees)}")

                return employees

            else:

                print(f"[DauofficeAPI] 조직 정보 오류: {data.get('message')}")

                return []

        return []



    def get_attendance_records(self, start_date, end_date, page=0, page_size=50):

        endpoint = "/public/api/attnd-v2/attnd"

        params = {"startDate": start_date, "endDate": end_date, "page": page, "pageSize": page_size}

        response = self._make_request("GET", endpoint, params=params)

        if response is None:

            return {'totalCount': 0, 'elements': [], 'totalPages': 0}

        print(f"[DauofficeAPI] 근태 조회 응답: {response.status_code} (page={page})")

        if response.status_code == 200:

            data = response.json()

            code = str(data.get('code', ''))

            if code == '200':

                raw = data.get('data', {})

                page_info = raw.get('page', {})

                return {

                    'totalCount': page_info.get('totalCount', 0),

                    'elements':   raw.get('elements', []),

                    'totalPages': page_info.get('totalPages', 1)

                }

        return {'totalCount': 0, 'elements': [], 'totalPages': 0}




    def sync_employees_from_dauoffice(self):

        """다우오피스 직원 동기화 - NORMAL 상태만, 부서노드 제외"""

        from models import db, Employee

        

        employees_data = self.get_organization_info()

        if not employees_data:

            print("[DauofficeAPI] 직원 데이터 없음")

            return 0



        synced = 0

        skipped_dept = 0

        deactivated = 0

        processed_login_ids = set()



        # ── PHASE 1: 다우오피스 계정 처리 (manual 연동 없이) ──────────────

        with db.session.no_autoflush:

            for emp_data in employees_data:

                login_id = emp_data.get('loginId', '').strip()

                if not login_id:

                    continue



                name        = emp_data.get('name', '').strip()

                status      = emp_data.get('status', '')

                user_groups = emp_data.get('userGroups', [])
                department  = _extract_department(emp_data)

                position    = emp_data.get('positionName')

                emp_number  = emp_data.get('employeeNumber')



                # userGroups 없는 직원(퇴사자/부서노드) 제외
                if not user_groups:
                    print(f"[DauofficeAPI] userGroups 없음(퇴사자) 제외: {name} ({login_id})")
                    skipped_dept += 1
                    continue



                # 비정상 계정 → 비활성 처리

                if status != 'NORMAL':

                    print(f"[DauofficeAPI] 비정상계정(퇴사/잠금): {name} status={status}")

                    existing = Employee.query.filter_by(dauoffice_user_id=login_id).first()

                    if existing:

                        existing.is_active = False

                        print(f"[DauofficeAPI]   → 비활성 처리: {name}")

                        deactivated += 1

                    continue



                processed_login_ids.add(login_id)



                # 기존 다우오피스 직원 찾기

                employee = Employee.query.filter_by(dauoffice_user_id=login_id).first()

                if employee:

                    employee.name       = name

                    employee.department = department

                    employee.is_active  = True

                    employee.data_source = 'dauoffice'

                else:

                    # 새로 생성

                    employee = Employee(

                        name             = name,

                        department       = department,

                        dauoffice_user_id= login_id,

                        data_source      = 'dauoffice',

                        is_active        = True

                    )

                    db.session.add(employee)



                synced += 1



        db.session.flush()



        # ── PHASE 2: 동일 이름 수동 직원 비활성화 ──────────────────────────

        with db.session.no_autoflush:

            manual_emps = Employee.query.filter_by(data_source='manual', is_active=True).all()

            for m in manual_emps:

                if not m.dauoffice_user_id:

                    dup = Employee.query.filter(

                        Employee.name == m.name,

                        Employee.data_source == 'dauoffice',

                        Employee.is_active == True

                    ).first()

                    if dup:

                        m.is_active = False

                        print(f"[DauofficeAPI] 수동중복 비활성화: {m.name}")





        # ── PHASE 3: 이번 sync 미포함 기존 직원 비활성화 ─────────────────

        if processed_login_ids:

            orphans = Employee.query.filter(

                Employee.data_source == 'dauoffice',

                Employee.is_active == True,

                ~Employee.dauoffice_user_id.in_(processed_login_ids)

            ).all()

            for emp in orphans:

                emp.is_active = False

                print(f"[DauofficeAPI] API미포함 비활성화: {emp.name} ({emp.dauoffice_user_id})")



        db.session.commit()

        print(f"[DauofficeAPI] 완료: {synced}명 동기화 / {skipped_dept}개 부서노드 제외 / {deactivated}명 퇴사처리")

        return synced


    def sync_attendance_from_dauoffice(self, year, month):

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

                employee = Employee.query.filter_by(dauoffice_user_id=login_id, is_active=True).first()

                if not employee:

                    continue

                accrual_date = att_data.get('accrualDate')

                if not accrual_date:

                    continue

                try:

                    date_obj = datetime.strptime(accrual_date, '%Y-%m-%d').date()

                except ValueError:

                    continue

                start_work_time = att_data.get('startWorkTime')

                check_in_time = None

                if start_work_time:

                    try:

                        check_in_time = datetime.strptime(start_work_time, '%Y-%m-%d %H:%M:%S').time()

                    except ValueError:

                        pass

                # 출근 기록 없으면 스킵
                if not check_in_time:
                    continue

                existing = AttendanceRecord.query.filter_by(employee_id=employee.id, date=date_obj).first()

                if not existing:

                    db.session.add(AttendanceRecord(

                        employee_id=employee.id, date=date_obj,

                        check_in_time=check_in_time, record_type='normal', data_source='dauoffice'

                    ))

                    synced_count += 1

                elif existing.data_source == 'dauoffice':

                    existing.check_in_time = check_in_time

                    synced_count += 1

            page += 1

            if page >= total_pages:

                break

        

        db.session.commit()

        print(f"[DauofficeAPI] 근태 동기화 완료: {synced_count}건")

        return synced_count

