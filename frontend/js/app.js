const { createApp } = Vue;
const API = window.location.hostname === 'localhost' ? 'http://localhost:5000/api' : '/api';

createApp({
    data() {
        return {
            selectedYear: new Date().getFullYear(),
            selectedMonth: new Date().getMonth() + 1,
            years: [2024, 2025, 2026, 2027],

            employees: [],
            attendanceData: [],
            daysInMonth: [],

            // 필터
            selectedDept: '',
            searchName: '',
            empSearchName: '',

            // UI 상태
            loading: false,
            globalLoading: false,
            loadingMessage: '처리 중...',
            showEmployeeModal: false,
            showAddEmployeeForm: false,
            showEditModal: false,

            // 토스트 알림
            toastMessage: '',
            toastType: 'success',  // success | danger | warning
            toastTimer: null,

            newEmployee: { name: '', department: '' },
            editingRecord: {
                recordId: null,
                employeeId: null,
                employeeName: '',
                department: '',
                date: '',
                day: null,
                recordType: 'normal',
                checkInTime: '',
                note: '',
                isNew: true   // ← 신규 vs 수정 구분
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
            return Object.entries(map)
                .sort((a, b) => a[0].localeCompare(b[0], 'ko'))
                .map(([name, count]) => ({ name, count }));
        },

        totalCount() { return this.attendanceData.length; },

        filteredData() {
            let data = this.attendanceData;
            if (this.selectedDept) {
                data = data.filter(e => (e.department || '미지정') === this.selectedDept);
            }
            if (this.searchName.trim()) {
                const q = this.searchName.trim();
                data = data.filter(e => (e.name || '').toLowerCase().includes(q.toLowerCase()));
            }
            return data;
        },

        filteredEmployees() {
            if (!this.empSearchName.trim()) return this.employees;
            const q = this.empSearchName.trim();
            return this.employees.filter(e =>
                e.name.includes(q) || (e.department || '').includes(q)
            );
        },

        // 모달 타이틀
        editModalTitle() {
            if (this.editingRecord.isNew) return '➕ 근태 기록 추가';
            return '✏️ 근태 기록 수정';
        }
    },

    mounted() {
        this.loadEmployees();
        this.loadAttendance();
    },

    methods: {
        // ── 토스트 알림 ──────────────────────────────
        showToast(msg, type = 'success') {
            if (this.toastTimer) clearTimeout(this.toastTimer);
            this.toastMessage = msg;
            this.toastType = type;
            this.toastTimer = setTimeout(() => { this.toastMessage = ''; }, 3000);
        },

        // ── 데이터 로드 ──────────────────────────────
        async loadEmployees() {
            try {
                const res = await axios.get(`${API}/employees`);
                this.employees = res.data;
            } catch (e) { console.error('직원 목록 로드 실패:', e); }
        },

        async loadAttendance() {
            this.loading = true;
            this.calculateDaysInMonth();
            try {
                const params = { year: this.selectedYear, month: this.selectedMonth };
                if (this.selectedDept) params.department = this.selectedDept;
                const res = await axios.get(`${API}/attendance`, { params });
                this.attendanceData = Array.isArray(res.data) ? res.data : (res.data.data || []);
            } catch (e) {
                console.error('출근 기록 로드 실패:', e);
                this.showToast('출근 기록 로드 실패', 'danger');
            } finally {
                this.loading = false;
            }
        },

        calculateDaysInMonth() {
            const y = this.selectedYear, m = this.selectedMonth;
            const total = new Date(y, m, 0).getDate();
            const wd = ['일','월','화','수','목','금','토'];
            this.daysInMonth = Array.from({ length: total }, (_, i) => {
                const d = new Date(y, m - 1, i + 1);
                return { day: i + 1, weekday: wd[d.getDay()], isWeekend: d.getDay() === 0 || d.getDay() === 6 };
            });
        },

        onDeptChange() {
            this.searchName = '';
            this.loadAttendance();
        },

        onSearchChange() {
            if (this.searchName.trim()) this.selectedDept = '';
        },

        // ── 셀 표시 ──────────────────────────────────
        getCellDisplay(empData, day) {
            const r = (empData.days || empData.records || {})[String(day)];
            if (!r) return '';
            const rtype = r.type || r.record_type;
            switch (rtype) {
                case 'annual_leave':       return '<span class="annual-leave">연 차</span>';
                case 'half_leave_am':      return '<span class="half-leave">반차(오전)</span>';
                case 'half_leave_pm':      return '<span class="half-leave">반차(오후)</span>';
                case 'half_leave':         return '<span class="half-leave">반 차</span>';
                case 'substitute_holiday': return '<span class="substitute">대체휴무</span>';
                case 'business_trip':      return `<span class="business-trip">출장${r.note ? '<br><small>' + r.note + '</small>' : ''}</span>`;
                case 'absent':             return '<span class="absent">결 근</span>';
                case 'sick_leave':         return '<span class="sick-leave">병 가</span>';
                case 'remote_work':        return '<span class="remote-work">재택근무</span>';
                default: {
                    const cin = r.check_in || r.check_in_time;
                    if (cin) {
                        const t = cin.substring(0, 5);
                        // 지각 여부 (09:30 초과)
                        const isLate = t > '09:30';
                        const timeSpan = isLate
                            ? `<span style="color:#dc3545;font-weight:bold">${t}⚠</span>`
                            : `<span style="color:#1a3a6b;font-weight:bold">${t}</span>`;
                        return r.note ? `${timeSpan}<br><small style="color:#888">${r.note}</small>` : timeSpan;
                    }
                    return '';
                }
            }
        },

        // ── 셀 클릭 → 모달 열기 ──────────────────────
        editCell(employee, day) {
            const dateStr = `${this.selectedYear}-${String(this.selectedMonth).padStart(2,'0')}-${String(day).padStart(2,'0')}`;
            const empData = this.attendanceData.find(e => e.id === employee.id);
            const rec = empData ? (empData.days || empData.records || {})[String(day)] : null;
            this.editingRecord = {
                recordId:     rec ? rec.id : null,
                employeeId:   employee.id,
                employeeName: employee.name,
                department:   employee.department || '',
                date:         dateStr,
                day,
                recordType:   rec ? (rec.type || rec.record_type || 'normal') : 'normal',
                checkInTime:  (rec && (rec.check_in || rec.check_in_time))
                                ? (rec.check_in || rec.check_in_time).substring(0, 5)
                                : '',
                note:         rec ? (rec.note || '') : '',
                isNew:        !rec
            };
            this.showEditModal = true;
        },

        // ── 저장 ─────────────────────────────────────
        async saveRecord() {
            this.globalLoading = true;
            this.loadingMessage = '저장 중...';
            try {
                const payload = {
                    employee_id: this.editingRecord.employeeId,
                    date:        this.editingRecord.date,
                    record_type: this.editingRecord.recordType,
                    note:        this.editingRecord.note
                };

                // 출근 시간 처리
                if (this.editingRecord.checkInTime) {
                    const t = this.editingRecord.checkInTime;
                    payload.check_in_time = t.length === 5 ? t + ':00' : t;
                } else if (this.editingRecord.recordType === 'normal') {
                    // 정상출근인데 시간 없으면 명시적으로 null 전송
                    payload.check_in_time = null;
                }
                // 연차/출장 등 비정상 타입은 check_in_time 보내지 않음 → 백엔드가 기존값 유지

                await axios.post(`${API}/attendance`, payload);
                this.showEditModal = false;
                await this.loadAttendance();

                const typeLabel = this.getTypeLabel(this.editingRecord.recordType);
                const action = this.editingRecord.isNew ? '추가' : '수정';
                this.showToast(`✅ ${this.editingRecord.employeeName} - ${typeLabel} ${action} 완료`);
            } catch (e) {
                console.error('저장 실패:', e);
                this.showToast('저장 실패: ' + (e.response?.data?.error || e.message), 'danger');
            } finally {
                this.globalLoading = false;
            }
        },

        // ── 삭제 ─────────────────────────────────────
        async deleteRecord() {
            if (!this.editingRecord.recordId) return;
            if (!confirm(`[${this.editingRecord.employeeName}] ${this.editingRecord.date} 기록을 삭제하시겠습니까?`)) return;
            this.globalLoading = true;
            try {
                await axios.delete(`${API}/attendance/${this.editingRecord.recordId}`);
                this.showEditModal = false;
                await this.loadAttendance();
                this.showToast(`🗑️ ${this.editingRecord.employeeName} 기록 삭제 완료`, 'warning');
            } catch (e) {
                this.showToast('삭제 실패: ' + (e.response?.data?.error || e.message), 'danger');
            } finally {
                this.globalLoading = false;
            }
        },

        // 기록 유형 한글 라벨
        getTypeLabel(type) {
            const map = {
                'normal':           '정상출근',
                'annual_leave':     '연차',
                'half_leave':       '반차',
                'half_leave_am':    '반차(오전)',
                'half_leave_pm':    '반차(오후)',
                'substitute_holiday': '대체휴무',
                'business_trip':    '출장',
                'absent':           '결근',
                'sick_leave':       '병가',
                'remote_work':      '재택근무'
            };
            return map[type] || type;
        },

        // ── 직원 추가/삭제 ────────────────────────────
        async addEmployee() {
            if (!this.newEmployee.name.trim()) { alert('성명을 입력해주세요.'); return; }
            this.globalLoading = true;
            try {
                await axios.post(`${API}/employees`, this.newEmployee);
                this.newEmployee = { name: '', department: '' };
                this.showAddEmployeeForm = false;
                await this.loadEmployees();
                await this.loadAttendance();
                this.showToast('✅ 직원 추가 완료');
            } catch (e) {
                this.showToast('직원 추가 실패: ' + (e.response?.data?.error || e.message), 'danger');
            } finally {
                this.globalLoading = false;
            }
        },

        async deleteEmployee(id) {
            if (!confirm('정말 삭제하시겠습니까?')) return;
            this.globalLoading = true;
            try {
                await axios.delete(`${API}/employees/${id}`);
                await this.loadEmployees();
                await this.loadAttendance();
                this.showToast('🗑️ 직원 삭제 완료', 'warning');
            } catch (e) {
                this.showToast('삭제 실패', 'danger');
            } finally {
                this.globalLoading = false;
            }
        },

        // ── 동기화 ────────────────────────────────────
        async syncFromDauoffice() {
            if (!confirm('다우오피스에서 직원 정보와 출근 기록을 동기화하시겠습니까?')) return;
            this.globalLoading = true;
            this.loadingMessage = '통합 동기화 중...';
            try {
                const empRes = await axios.post(`${API}/daou/sync/employees`);
                const attRes = await axios.post(`${API}/daou/sync/attendance`, {
                    year: this.selectedYear, month: this.selectedMonth
                });
                let slMsg = '';
                try {
                    const slRes = await axios.post(`${API}/senselink/sync`, {
                        year: this.selectedYear, month: this.selectedMonth
                    });
                    slMsg = `\nSenseLink: ${slRes.data.synced || 0}건`;
                } catch(se) {
                    slMsg = '\nSenseLink: 연결 실패';
                }
                await this.loadEmployees();
                await this.loadAttendance();
                this.showToast(`통합 동기화 완료! 직원:${empRes.data.count}명 / 출근:${attRes.data.count}개${slMsg}`);
            } catch (e) {
                this.showToast('동기화 실패: ' + (e.response?.data?.error || e.message), 'danger');
            } finally {
                this.globalLoading = false;
            }
        },

        // ── 엑셀 다운로드 ─────────────────────────────
        exportExcel() {
            const dept = this.selectedDept ? `&department=${encodeURIComponent(this.selectedDept)}` : '';
            const url  = `${API}/export/excel?year=${this.selectedYear}&month=${this.selectedMonth}${dept}`;
            const deptLabel = this.selectedDept || '전체';
            const fname = `출근기록_${this.selectedYear}.${String(this.selectedMonth).padStart(2,'0')}_${deptLabel}.xlsx`;

            this.globalLoading = true;
            this.loadingMessage = '엑셀 파일 생성 중...';

            fetch(url)
                .then(res => {
                    if (!res.ok) throw new Error('서버 오류: ' + res.status);
                    return res.blob();
                })
                .then(blob => {
                    const a = document.createElement('a');
                    a.href = URL.createObjectURL(blob);
                    a.download = fname;
                    document.body.appendChild(a);
                    a.click();
                    document.body.removeChild(a);
                    URL.revokeObjectURL(a.href);
                })
                .catch(err => this.showToast('엑셀 다운로드 실패: ' + err.message, 'danger'))
                .finally(() => { this.globalLoading = false; });
        }
    }
}).mount('#app');
