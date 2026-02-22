const { createApp } = Vue;

// API 베이스 URL (개발 환경: localhost, 프로덕션: /api)
const API_BASE_URL = window.location.hostname === 'localhost' ? 'http://localhost:5000/api' : '/api';

createApp({
    data() {
        return {
            // 현재 선택된 년/월
            selectedYear: new Date().getFullYear(),
            selectedMonth: new Date().getMonth() + 1,
            years: [2024, 2025, 2026, 2027],
            
            // 데이터
            employees: [],
            attendanceData: [],
            daysInMonth: [],
            
            // UI 상태
            loading: false,
            showEmployeeModal: false,
            showAddEmployeeForm: false,
            showEditModal: false,
            
            // 직원 추가
            newEmployee: {
                name: '',
                department: ''
            },
            
            // 출근 기록 편집
            editingRecord: {
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
    
    mounted() {
        this.loadEmployees();
        this.loadAttendance();
    },
    
    methods: {
        // 직원 목록 로드
        async loadEmployees() {
            try {
                const response = await axios.get(`${API_BASE_URL}/employees`);
                this.employees = response.data;
            } catch (error) {
                console.error('직원 목록 로드 실패:', error);
                alert('직원 목록을 불러오는데 실패했습니다.');
            }
        },
        
        // 출근 기록 로드
        async loadAttendance() {
            this.loading = true;
            try {
                // 해당 월의 일수 계산
                this.calculateDaysInMonth();
                
                // 출근 기록 조회
                const response = await axios.get(`${API_BASE_URL}/attendance`, {
                    params: {
                        year: this.selectedYear,
                        month: this.selectedMonth
                    }
                });
                
                this.attendanceData = response.data;
            } catch (error) {
                console.error('출근 기록 로드 실패:', error);
                alert('출근 기록을 불러오는데 실패했습니다.');
            } finally {
                this.loading = false;
            }
        },
        
        // 해당 월의 일수 계산
        calculateDaysInMonth() {
            const year = this.selectedYear;
            const month = this.selectedMonth;
            const daysInMonth = new Date(year, month, 0).getDate();
            
            this.daysInMonth = [];
            
            for (let day = 1; day <= daysInMonth; day++) {
                const date = new Date(year, month - 1, day);
                const weekdayIndex = date.getDay();
                const weekdays = ['일', '월', '화', '수', '목', '금', '토'];
                
                this.daysInMonth.push({
                    day: day,
                    weekday: weekdays[weekdayIndex],
                    isWeekend: weekdayIndex === 0 || weekdayIndex === 6
                });
            }
        },
        
        // 셀 표시 내용 가져오기
        getCellDisplay(empData, day) {
            const record = empData.records[day];
            
            if (!record) {
                return '';
            }
            
            if (record.record_type === 'annual_leave') {
                return '<span class="annual-leave">연 차</span>';
            } else if (record.record_type === 'half_leave') {
                return '<span class="annual-leave">반 차</span>';
            } else if (record.record_type === 'substitute_holiday') {
                return '<span class="annual-leave">대체휴무</span>';
            } else if (record.record_type === 'business_trip') {
                const note = record.note ? `-${record.note}` : '';
                return `<span class="business-trip">출장${note}</span>`;
            } else if (record.check_in_time) {
                let display = record.check_in_time;
                if (record.note) {
                    display += `<br><small>${record.note}</small>`;
                }
                return display;
            }
            
            return '';
        },
        
        // 셀 편집
        editCell(employee, day) {
            const dateStr = `${this.selectedYear}-${String(this.selectedMonth).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
            
            // 해당 직원의 해당 날짜 기록 찾기
            const empData = this.attendanceData.find(e => e.employee.id === employee.id);
            const record = empData ? empData.records[day] : null;
            
            this.editingRecord = {
                employeeId: employee.id,
                employeeName: employee.name,
                date: dateStr,
                day: day,
                recordType: record ? record.record_type : 'normal',
                checkInTime: record && record.check_in_time ? record.check_in_time : '',
                note: record ? record.note || '' : ''
            };
            
            this.showEditModal = true;
        },
        
        // 출근 기록 저장
        async saveRecord() {
            this.loading = true;
            try {
                const payload = {
                    employee_id: this.editingRecord.employeeId,
                    date: this.editingRecord.date,
                    record_type: this.editingRecord.recordType,
                    note: this.editingRecord.note
                };
                
                // 정상 출근인 경우에만 시간 추가
                if (this.editingRecord.recordType === 'normal' && this.editingRecord.checkInTime) {
                    payload.check_in_time = this.editingRecord.checkInTime + ':00';
                }
                
                await axios.post(`${API_BASE_URL}/attendance`, payload);
                
                this.showEditModal = false;
                await this.loadAttendance();
                
                alert('저장되었습니다.');
            } catch (error) {
                console.error('저장 실패:', error);
                alert('저장에 실패했습니다: ' + (error.response?.data?.error || error.message));
            } finally {
                this.loading = false;
            }
        },
        
        // 직원 추가
        async addEmployee() {
            if (!this.newEmployee.name) {
                alert('성명을 입력해주세요.');
                return;
            }
            
            this.loading = true;
            try {
                await axios.post(`${API_BASE_URL}/employees`, this.newEmployee);
                
                this.newEmployee = { name: '', department: '' };
                this.showAddEmployeeForm = false;
                
                await this.loadEmployees();
                await this.loadAttendance();
                
                alert('직원이 추가되었습니다.');
            } catch (error) {
                console.error('직원 추가 실패:', error);
                alert('직원 추가에 실패했습니다.');
            } finally {
                this.loading = false;
            }
        },
        
        // 직원 삭제
        async deleteEmployee(employeeId) {
            if (!confirm('정말 이 직원을 삭제하시겠습니까?')) {
                return;
            }
            
            this.loading = true;
            try {
                await axios.delete(`${API_BASE_URL}/employees/${employeeId}`);
                
                await this.loadEmployees();
                await this.loadAttendance();
                
                alert('직원이 삭제되었습니다.');
            } catch (error) {
                console.error('직원 삭제 실패:', error);
                alert('직원 삭제에 실패했습니다.');
            } finally {
                this.loading = false;
            }
        },
        
        // 다우오피스 동기화
        async syncFromDauoffice() {
            if (!confirm('다우오피스에서 직원 정보와 출근 기록을 가져오시겠습니까?')) {
                return;
            }
            
            this.loading = true;
            try {
                // 직원 동기화
                const empResponse = await axios.post(`${API_BASE_URL}/dauoffice/sync-employees`);
                console.log('직원 동기화:', empResponse.data);
                
                // 출근 기록 동기화
                const attResponse = await axios.post(`${API_BASE_URL}/dauoffice/sync-attendance`, {
                    year: this.selectedYear,
                    month: this.selectedMonth
                });
                console.log('출근 기록 동기화:', attResponse.data);
                
                await this.loadEmployees();
                await this.loadAttendance();
                
                alert(`동기화 완료!\n직원: ${empResponse.data.count}명\n출근기록: ${attResponse.data.count}개`);
            } catch (error) {
                console.error('동기화 실패:', error);
                alert('동기화에 실패했습니다: ' + (error.response?.data?.error || error.message));
            } finally {
                this.loading = false;
            }
        },
        
        // 엑셀 다운로드
        exportExcel() {
            const url = `${API_BASE_URL}/export/excel?year=${this.selectedYear}&month=${this.selectedMonth}`;
            window.open(url, '_blank');
        }
    }
}).mount('#app');
