const { createApp } = Vue;
const API = window.location.hostname === 'localhost' ? 'http://localhost:5000/api' : '/api';

createApp({
    data() {
        return {
            selectedYear: new Date().getFullYear(),
            selectedMonth: new Date().getMonth() + 1,
            years: [2024, 2025, 2026, 2027],

            employees: [],
            attendanceData: [],   // 전체 raw 데이터
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

            newEmployee: { name: '', department: '' },
            editingRecord: {
                recordId: null,
                employeeId: null,
                employeeName: '',
                date: '',
                day: null,
                recordType: 'normal',
                checkInTime: '',
                note: ''
            }
        };
    },

    computed: {
        // 부서 목록 (직원 수 포함)
        departments() {
            const map = {};
            for (const emp of this.attendanceData) {
                const dept = emp.employee.department || '미지정';
                map[dept] = (map[dept] || 0) + 1;
            }
            return Object.entries(map)
                .sort((a, b) => a[0].localeCompare(b[0], 'ko'))
                .map(([name, count]) => ({ name, count }));
        },

        totalCount() {
            return this.attendanceData.length;
        },

        // 부서 + 이름 필터 적용된 데이터
        filteredData() {
            let data = this.attendanceData;
            if (this.selectedDept) {
                data = data.filter(e => (e.employee.department || '미지정') === this.selectedDept);
            }
            if (this.searchName.trim()) {
                const q = this.searchName.trim();
                data = data.filter(e => e.employee.name.includes(q));
            }
            return data;
        },

        // 직원 관리 모달 필터
        filteredEmployees() {
            if (!this.empSearchName.trim()) return this.employees;
            const q = this.empSearchName.trim();
            return this.employees.filter(e =>
                e.name.includes(q) || (e.department || '').includes(q)
            );
        }
    },

    mounted() {
        this.loadEmployees();
        this.loadAttendance();
    },

    methods: {
        async loadEmployees() {
            try {
                const res = await axios.get(`${API}/employees`);
                this.employees = res.data;
            } catch (e) {
                console.error('직원 목록 로드 실패:', e);
            }
        },

        async loadAttendance() {
            this.loading = true;
            this.calculateDaysInMonth();
            try {
                const params = { year: this.selectedYear, month: this.selectedMonth };
                if (this.selectedDept) params.department = this.selectedDept;
                const res = await axios.get(`${API}/attendance`, { params });
                this.attendanceData = res.data;
            } catch (e) {
                console.error('출근 기록 로드 실패:', e);
                alert('출근 기록을 불러오는데 실패했습니다.');
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
            this.loadAttendance();  // 부서 변경 시 API 재호출
        },

        onSearchChange() {
            // 이름 검색 시 부서 필터 초기화
            if (this.searchName.trim()) this.selectedDept = '';
        },

        getCellDisplay(empData, day) {
            const r = empData.records[day];
            if (!r) return '';
            switch (r.record_type) {
                case 'annual_leave':    return '<span class="annual-leave">연 차</span>';
                case 'half_leave':      return '<span class="half-leave">반 차</span>';
                case 'substitute_holiday': return '<span class="substitute">대체휴무</span>';
                case 'business_trip':   return `<span class="business-trip">출장${r.note ? '-'+r.note : ''}</span>`;
                case 'absent':          return '<span style="color:#6c757d">결 근</span>';
                default:
                    if (r.check_in_time) {
                        const t = r.check_in_time.substring(0, 5); // HH:MM
                        return r.note ? `${t}<br><small style="color:#888">${r.note}</small>` : t;
                    }
                    return '';
            }
        },

        editCell(employee, day) {
            const dateStr = `${this.selectedYear}-${String(this.selectedMonth).padStart(2,'0')}-${String(day).padStart(2,'0')}`;
            const empData = this.attendanceData.find(e => e.employee.id === employee.id);
            const rec = empData ? empData.records[day] : null;
            this.editingRecord = {
                recordId: rec ? rec.id : null,
                employeeId: employee.id,
                employeeName: employee.name,
                date: dateStr,
                day,
                recordType: rec ? rec.record_type : 'normal',
                checkInTime: rec && rec.check_in_time ? rec.check_in_time.substring(0, 5) : '',
                note: rec ? (rec.note || '') : ''
            };
            this.showEditModal = true;
        },

        async saveRecord() {
            this.globalLoading = true;
            this.loadingMessage = '저장 중...';
            try {
                const payload = {
                    employee_id: this.editingRecord.employeeId,
                    date: this.editingRecord.date,
                    record_type: this.editingRecord.recordType,
                    note: this.editingRecord.note
                };
                if (this.editingRecord.recordType === 'normal' && this.editingRecord.checkInTime) {
                    const t = this.editingRecord.checkInTime;
                    payload.check_in_time = t.length === 5 ? t + ':00' : t;
                }
                await axios.post(`${API}/attendance`, payload);
                this.showEditModal = false;
                await this.loadAttendance();
            } catch (e) {
                console.error('저장 실패:', e);
                alert('저장 실패: ' + (e.response?.data?.error || e.message));
            } finally {
                this.globalLoading = false;
            }
        },

        async deleteRecord() {
            if (!this.editingRecord.recordId) return;
            if (!confirm('이 출근 기록을 삭제하시겠습니까?')) return;
            this.globalLoading = true;
            try {
                await axios.delete(`${API}/attendance/${this.editingRecord.recordId}`);
                this.showEditModal = false;
                await this.loadAttendance();
            } catch (e) {
                alert('삭제 실패: ' + (e.response?.data?.error || e.message));
            } finally {
                this.globalLoading = false;
            }
        },

        async addEmployee() {
            if (!this.newEmployee.name.trim()) { alert('성명을 입력해주세요.'); return; }
            this.globalLoading = true;
            try {
                await axios.post(`${API}/employees`, this.newEmployee);
                this.newEmployee = { name: '', department: '' };
                this.showAddEmployeeForm = false;
                await this.loadEmployees();
                await this.loadAttendance();
            } catch (e) {
                alert('직원 추가 실패: ' + (e.response?.data?.error || e.message));
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
            } catch (e) {
                alert('삭제 실패');
            } finally {
                this.globalLoading = false;
            }
        },

        async syncFromDauoffice() {
            if (!confirm('다우오피스에서 직원 정보와 출근 기록을 동기화하시겠습니까?')) return;
            this.globalLoading = true;
            this.loadingMessage = '다우오피스 동기화 중...';
            try {
                const empRes = await axios.post(`${API}/dauoffice/sync-employees`);
                const attRes = await axios.post(`${API}/dauoffice/sync-attendance`, {
                    year: this.selectedYear, month: this.selectedMonth
                });
                await this.loadEmployees();
                await this.loadAttendance();
                alert(`동기화 완료!\n직원: ${empRes.data.count}명\n출근기록: ${attRes.data.count}개`);
            } catch (e) {
                alert('동기화 실패: ' + (e.response?.data?.error || e.message));
            } finally {
                this.globalLoading = false;
            }
        },

        exportExcel() {
            const dept = this.selectedDept ? `&department=${encodeURIComponent(this.selectedDept)}` : '';
            window.open(`${API}/export/excel?year=${this.selectedYear}&month=${this.selectedMonth}${dept}`, '_blank');
        }
    }
}).mount('#app');
