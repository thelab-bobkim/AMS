const { createApp } = Vue;
const API = window.location.hostname === 'localhost' ? 'http://localhost:5000/api' : '/api';

// ── Axios 인터셉터: 모든 요청에 JWT 토큰 자동 첨부 ──
axios.interceptors.request.use(cfg => {
    const token = localStorage.getItem('ams_token');
    if (token) cfg.headers['Authorization'] = 'Bearer ' + token;
    return cfg;
});

createApp({
    data() {
        return {
            // ── 인증 ──────────────────────────────────────
            isLoggedIn:   false,
            isAdmin:      false,
            currentUser:  '',
            loginForm:    { username: '', password: '' },
            loginError:   '',
            loginLoading: false,

            // ── 비밀번호 변경 ─────────────────────────────
            showPwModal:  false,
            pwForm:       { old_password: '', new_password: '', confirm: '' },
            pwError:      '', pwSuccess: '',

            // ── 관리자 목록 모달 ──────────────────────────
            showAdminModal: false,
            adminList:      [],
            adminPwForm:    { id: null, username: '', new_password: '' },
            showAdminPwForm: false,

            // ── 데이터 ────────────────────────────────────
            selectedYear:  new Date().getFullYear(),
            selectedMonth: new Date().getMonth() + 1,
            years: [2024, 2025, 2026, 2027],
            employees: [], attendanceData: [], daysInMonth: [],

            // ── 필터 ──────────────────────────────────────
            selectedDept: '', searchName: '', empSearchName: '',

            // ── UI 상태 ───────────────────────────────────
            loading: false, globalLoading: false, loadingMessage: '처리 중...',
            showEmployeeModal: false, showAddEmployeeForm: false, showEditModal: false,

            // ── 토스트 ────────────────────────────────────
            toastMessage: '', toastType: 'success', toastTimer: null,

            newEmployee: { name: '', department: '' },
            editingRecord: {
                recordId: null, employeeId: null, employeeName: '',
                department: '', date: '', day: null,
                recordType: 'normal', checkInTime: '', note: '', isNew: true
            }
        };
    },

    computed: {
        departments() {
            const map = {};
            for (const emp of this.attendanceData) {
                const dept = emp.department || '미지정';
                map[dept] = (map[dept] || 0) + 1;
            }
            return Object.entries(map).sort((a,b)=>a[0].localeCompare(b[0],'ko')).map(([name,count])=>({name,count}));
        },
        totalCount() { return this.attendanceData.length; },
        filteredData() {
            let data = this.attendanceData;
            if (this.selectedDept) data = data.filter(e => (e.department||'미지정')===this.selectedDept);
            if (this.searchName.trim()) {
                const q = this.searchName.trim();
                data = data.filter(e => (e.name||'').toLowerCase().includes(q.toLowerCase()));
            }
            return data;
        },
        filteredEmployees() {
            if (!this.empSearchName.trim()) return this.employees;
            const q = this.empSearchName.trim();
            return this.employees.filter(e => e.name.includes(q)||(e.department||'').includes(q));
        },
        editModalTitle() {
            return this.editingRecord.isNew ? '➕ 근태 기록 추가' : '✏️ 근태 기록 수정';
        }
    },

    async mounted() {
        // 저장된 토큰으로 자동 로그인 시도
        const token = localStorage.getItem('ams_token');
        if (token) {
            try {
                const res = await axios.get(`${API}/auth/verify`);
                if (res.data.valid) {
                    this.isLoggedIn  = true;
                    this.isAdmin     = res.data.is_admin;
                    this.currentUser = res.data.username;
                    this.loadEmployees();
                    this.loadAttendance();
                } else { this.logout(); }
            } catch { this.logout(); }
        }
    },

    methods: {
        // ── 토스트 ────────────────────────────────────────
        showToast(msg, type='success') {
            if (this.toastTimer) clearTimeout(this.toastTimer);
            this.toastMessage = msg; this.toastType = type;
            this.toastTimer = setTimeout(() => { this.toastMessage=''; }, 3000);
        },

        // ══════════════════════════════════════════════════
        //  인증
        // ══════════════════════════════════════════════════
        async doLogin() {
            if (!this.loginForm.username || !this.loginForm.password) {
                this.loginError = '아이디와 비밀번호를 입력하세요.'; return;
            }
            this.loginLoading = true; this.loginError = '';
            try {
                const res = await axios.post(`${API}/auth/login`, this.loginForm);
                localStorage.setItem('ams_token', res.data.token);
                this.isLoggedIn  = true;
                this.isAdmin     = res.data.is_admin;
                this.currentUser = res.data.username;
                this.loginForm   = { username:'', password:'' };
                await this.loadEmployees();
                await this.loadAttendance();
            } catch(e) {
                this.loginError = e.response?.data?.error || '로그인 실패';
            } finally { this.loginLoading = false; }
        },

        logout() {
            localStorage.removeItem('ams_token');
            this.isLoggedIn=false; this.isAdmin=false; this.currentUser='';
            this.attendanceData=[]; this.employees=[];
        },

        // ── 비밀번호 변경 ─────────────────────────────────
        openPwModal() { this.pwForm={old_password:'',new_password:'',confirm:''}; this.pwError=''; this.pwSuccess=''; this.showPwModal=true; },
        async changePassword() {
            // 비밀번호는 서버 .env의 ADMIN_PASSWORD / USER_DEFAULT_PASSWORD로 관리됩니다.
            this.pwSuccess = '비밀번호 변경은 서버 관리자에게 문의하세요.\n(서버 .env 파일의 ADMIN_PASSWORD 항목)';
            setTimeout(()=>{ this.showPwModal=false; }, 2500);
        },

        // ── 관리자 계정 관리 ──────────────────────────────
        async openAdminModal() {
            try {
                const res = await axios.get(`${API}/auth/admins`);
                this.adminList = res.data;
                this.showAdminModal = true; this.showAdminPwForm = false;
            } catch(e) { this.showToast('관리자 목록 로드 실패', 'danger'); }
        },
        openAdminPwForm(admin) {
            this.adminPwForm = { id: admin.id, username: admin.username, new_password: '' };
            this.showAdminPwForm = true;
        },
        async resetAdminPassword() {
            // .env 기반 관리자 계정: 비밀번호는 ADMIN_PASSWORD로 일괄 관리
            this.showToast('관리자 비밀번호는 서버 .env의 ADMIN_PASSWORD에서 변경하세요.', 'warning');
            this.showAdminPwForm = false;
        },

        // ══════════════════════════════════════════════════
        //  데이터 로드
        // ══════════════════════════════════════════════════
        async loadEmployees() {
            try {
                const res = await axios.get(`${API}/employees`);
                this.employees = res.data;
            } catch(e) {
                if (e.response?.status === 401) this.logout();
                console.error('직원 목록 로드 실패:', e);
            }
        },

        async loadAttendance() {
            this.loading = true; this.calculateDaysInMonth();
            try {
                const params = { year: this.selectedYear, month: this.selectedMonth };
                if (this.selectedDept && this.isAdmin) params.department = this.selectedDept;
                const res = await axios.get(`${API}/attendance`, { params });
                this.attendanceData = Array.isArray(res.data) ? res.data : (res.data.data || []);
            } catch(e) {
                if (e.response?.status === 401) this.logout();
                this.showToast('출근 기록 로드 실패', 'danger');
            } finally { this.loading = false; }
        },

        calculateDaysInMonth() {
            const y=this.selectedYear, m=this.selectedMonth;
            const total=new Date(y,m,0).getDate();
            const wd=['일','월','화','수','목','금','토'];
            this.daysInMonth=Array.from({length:total},(_,i)=>{
                const d=new Date(y,m-1,i+1);
                return {day:i+1,weekday:wd[d.getDay()],isWeekend:d.getDay()===0||d.getDay()===6};
            });
        },

        onDeptChange() { this.searchName=''; this.loadAttendance(); },
        onSearchChange() { if (this.searchName.trim()) this.selectedDept=''; },

        // ── 셀 표시 ───────────────────────────────────────
        getCellDisplay(empData, day) {
            const r = (empData.days||empData.records||{})[String(day)];
            if (!r) return '';
            const rtype = r.type||r.record_type;
            switch(rtype) {
                case 'annual_leave':       return '<span class="annual-leave">연 차</span>';
                case 'half_leave_am':      return '<span class="half-leave">반차(오전)</span>';
                case 'half_leave_pm':      return '<span class="half-leave">반차(오후)</span>';
                case 'half_leave':         return '<span class="half-leave">반 차</span>';
                case 'substitute_holiday': return '<span class="substitute">대체휴무</span>';
                case 'business_trip':      return `<span class="business-trip">출장${r.note?'<br><small>'+r.note+'</small>':''}</span>`;
                case 'absent':             return '<span class="absent">결 근</span>';
                case 'sick_leave':         return '<span class="sick-leave">병 가</span>';
                case 'remote_work':        return '<span class="remote-work">재택근무</span>';
                default: {
                    const cin=r.check_in||r.check_in_time;
                    if (cin) {
                        const t=cin.substring(0,5);
                        const isLate=t>'09:30';
                        const span=isLate?`<span style="color:#dc3545;font-weight:bold">${t}⚠</span>`:`<span style="color:#1a3a6b;font-weight:bold">${t}</span>`;
                        return r.note?`${span}<br><small style="color:#888">${r.note}</small>`:span;
                    }
                    return '';
                }
            }
        },

        // ── 셀 클릭 ───────────────────────────────────────
        editCell(employee, day) {
            const dateStr=`${this.selectedYear}-${String(this.selectedMonth).padStart(2,'0')}-${String(day).padStart(2,'0')}`;
            const empData=this.attendanceData.find(e=>e.id===employee.id);
            const rec=empData?(empData.days||empData.records||{})[String(day)]:null;

            // 🔐 일반 사용자: 본인 기록만 편집 가능
            if (!this.isAdmin && employee.name !== this.currentUser) {
                this.showToast('본인의 기록만 편집할 수 있습니다.', 'warning');
                return;
            }

            this.editingRecord={
                recordId:     rec?rec.id:null,
                employeeId:   employee.id,
                employeeName: employee.name,
                department:   employee.department||'',
                date:         dateStr, day,
                recordType:   rec?(rec.type||rec.record_type||'normal'):'normal',
                checkInTime:  (rec&&(rec.check_in||rec.check_in_time))?(rec.check_in||rec.check_in_time).substring(0,5):'',
                note:         rec?(rec.note||''):'',
                isNew:        !rec
            };
            this.showEditModal=true;
        },

        // ── 저장 ──────────────────────────────────────────
        async saveRecord() {
            this.globalLoading=true; this.loadingMessage='저장 중...';
            try {
                const payload={
                    employee_id: this.editingRecord.employeeId,
                    date:        this.editingRecord.date,
                    record_type: this.editingRecord.recordType,
                    note:        this.editingRecord.note
                };
                if (this.editingRecord.checkInTime) {
                    const t=this.editingRecord.checkInTime;
                    payload.check_in_time=t.length===5?t+':00':t;
                } else if (this.editingRecord.recordType==='normal') {
                    payload.check_in_time=null;
                }
                await axios.post(`${API}/attendance`, payload);
                this.showEditModal=false;
                await this.loadAttendance();
                const typeLabel=this.getTypeLabel(this.editingRecord.recordType);
                const action=this.editingRecord.isNew?'추가':'수정';
                this.showToast(`✅ ${this.editingRecord.employeeName} - ${typeLabel} ${action} 완료`);
            } catch(e) {
                const msg = e.response?.data?.error || e.message;
                if (e.response?.status===403) this.showToast('권한이 없습니다: ' + msg, 'danger');
                else if (e.response?.status===401) { this.logout(); }
                else this.showToast('저장 실패: ' + msg, 'danger');
            } finally { this.globalLoading=false; }
        },

        // ── 삭제 ──────────────────────────────────────────
        async deleteRecord() {
            if (!this.editingRecord.recordId) return;
            if (!confirm(`[${this.editingRecord.employeeName}] ${this.editingRecord.date} 기록을 삭제하시겠습니까?`)) return;
            this.globalLoading=true;
            try {
                await axios.delete(`${API}/attendance/${this.editingRecord.recordId}`);
                this.showEditModal=false;
                await this.loadAttendance();
                this.showToast(`🗑️ ${this.editingRecord.employeeName} 기록 삭제 완료`, 'warning');
            } catch(e) {
                const msg = e.response?.data?.error || e.message;
                if (e.response?.status===403) this.showToast('권한이 없습니다: ' + msg, 'danger');
                else this.showToast('삭제 실패: ' + msg, 'danger');
            } finally { this.globalLoading=false; }
        },

        getTypeLabel(type) {
            const map={ normal:'정상출근', annual_leave:'연차', half_leave:'반차', half_leave_am:'반차(오전)', half_leave_pm:'반차(오후)', substitute_holiday:'대체휴무', business_trip:'출장', absent:'결근', sick_leave:'병가', remote_work:'재택근무' };
            return map[type]||type;
        },

        // ── 직원 추가/삭제 ────────────────────────────────
        async addEmployee() {
            if (!this.newEmployee.name.trim()) { alert('성명을 입력해주세요.'); return; }
            this.globalLoading=true;
            try {
                await axios.post(`${API}/employees`, this.newEmployee);
                this.newEmployee={name:'',department:''}; this.showAddEmployeeForm=false;
                await this.loadEmployees(); await this.loadAttendance();
                this.showToast('✅ 직원 추가 완료');
            } catch(e) { this.showToast('직원 추가 실패: '+(e.response?.data?.error||e.message), 'danger'); }
            finally { this.globalLoading=false; }
        },

        async deleteEmployee(id) {
            if (!confirm('정말 삭제하시겠습니까?')) return;
            this.globalLoading=true;
            try {
                await axios.delete(`${API}/employees/${id}`);
                await this.loadEmployees(); await this.loadAttendance();
                this.showToast('🗑️ 직원 삭제 완료', 'warning');
            } catch(e) { this.showToast('삭제 실패', 'danger'); }
            finally { this.globalLoading=false; }
        },

        // ── 동기화 ────────────────────────────────────────
        async syncFromDauoffice() {
            if (!confirm('다우오피스에서 직원 정보와 출근 기록을 동기화하시겠습니까?')) return;
            this.globalLoading=true; this.loadingMessage='통합 동기화 중...';
            try {
                const empRes=await axios.post(`${API}/daou/sync/employees`);
                const attRes=await axios.post(`${API}/daou/sync/attendance`,{year:this.selectedYear,month:this.selectedMonth});
                let slMsg='';
                try {
                    const slRes=await axios.post(`${API}/senselink/sync`,{year:this.selectedYear,month:this.selectedMonth});
                    slMsg=`\nSenseLink: ${slRes.data.synced||0}건`;
                } catch { slMsg='\nSenseLink: 연결 실패'; }
                await this.loadEmployees(); await this.loadAttendance();
                this.showToast(`통합 동기화 완료! 직원:${empRes.data.count}명 / 출근:${attRes.data.count}개${slMsg}`);
            } catch(e) { this.showToast('동기화 실패: '+(e.response?.data?.error||e.message), 'danger'); }
            finally { this.globalLoading=false; }
        },

        // ── 엑셀 ──────────────────────────────────────────
        exportExcel() {
            const dept=this.selectedDept?`&department=${encodeURIComponent(this.selectedDept)}`:'';
            const url=`${API}/export/excel?year=${this.selectedYear}&month=${this.selectedMonth}${dept}`;
            const fname=`출근기록_${this.selectedYear}.${String(this.selectedMonth).padStart(2,'0')}_${this.selectedDept||'전체'}.xlsx`;
            this.globalLoading=true; this.loadingMessage='엑셀 파일 생성 중...';
            const token=localStorage.getItem('ams_token');
            fetch(url,{headers:{Authorization:'Bearer '+token}})
                .then(res=>{ if(!res.ok) throw new Error('서버 오류: '+res.status); return res.blob(); })
                .then(blob=>{ const a=document.createElement('a'); a.href=URL.createObjectURL(blob); a.download=fname; document.body.appendChild(a); a.click(); document.body.removeChild(a); URL.revokeObjectURL(a.href); })
                .catch(err=>this.showToast('엑셀 다운로드 실패: '+err.message,'danger'))
                .finally(()=>{ this.globalLoading=false; });
        }
    }
}).mount('#app');
