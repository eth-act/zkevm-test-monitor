// Main dashboard JavaScript
class ComplianceDashboard {
    constructor() {
        this.data = null;
        this.historicalData = {};
        this.chart = null;
        this.init();
    }

    async init() {
        try {
            await this.loadData();
        } catch (error) {
            console.error('Error loading data:', error);
            // If data fails to load, use empty structure
            this.data = {
                zkvms: {},
                last_updated: null
            };
        }
        
        // Always try to render, even with empty or partial data
        this.renderDashboard();
        this.startAutoRefresh();
    }

    async loadData() {
        try {
            console.log('Loading data from data/current/status.json...');
            // Load current status
            const response = await fetch('data/current/status.json');
            console.log('Response status:', response.status);
            
            if (!response.ok) {
                throw new Error(`HTTP ${response.status}: ${response.statusText}`);
            }
            
            const text = await response.text();
            console.log('Raw response length:', text.length);
            
            this.data = JSON.parse(text);
            console.log('Data parsed successfully:', this.data);

            // Load historical data for each ZKVM
            for (const zkvm in this.data.zkvms) {
                this.historicalData[zkvm] = await this.loadHistoricalData(zkvm);
            }
            console.log('Historical data loaded');
        } catch (error) {
            console.error('Error loading data:', error);
            console.error('Error details:', error.message);
            // Don't use mock data - let the error propagate
            throw error;
        }
    }

    async loadHistoricalData(zkvm) {
        const history = [];
        const currentDate = new Date();
        
        // Try to load last 90 days of data
        for (let i = 0; i < 90; i++) {
            const date = new Date(currentDate);
            date.setDate(date.getDate() - i);
            const monthDir = date.toISOString().slice(0, 7);
            const fileName = `${zkvm}-${date.toISOString().slice(0, 10).replace(/-/g, '')}-*.json`;
            
            // In a real implementation, we'd fetch actual files
            // For now, we'll use the current data as historical placeholder
            if (i % 7 === 0 && this.data.zkvms[zkvm]) {
                history.push({
                    date: date.toISOString(),
                    ...this.data.zkvms[zkvm]
                });
            }
        }
        
        return history;
    }

    getMockData() {
        // Return empty data structure when real data fails to load
        // No hardcoded test results - only structure
        return {
            zkvms: {},
            last_updated: new Date().toISOString()
        };
    }

    renderDashboard() {
        console.log('Rendering dashboard with data:', this.data);
        this.updateLastUpdated();
        this.renderComplianceTable();
    }

    updateLastUpdated() {
        const element = document.getElementById('last-updated');
        if (this.data && this.data.last_updated) {
            const date = new Date(this.data.last_updated);
            element.textContent = `Last updated: ${date.toLocaleString()}`;
        } else {
            element.textContent = 'Last updated: Never';
        }
    }

    renderSummaryCards() {
        const container = document.getElementById('summary-cards');
        container.innerHTML = '';

        // Calculate totals
        let totalPassed = 0;
        let totalTests = 0;
        let totalZKVMs = 0;

        for (const zkvm in this.data.zkvms) {
            const data = this.data.zkvms[zkvm];
            totalPassed += data.passed || 0;
            totalTests += data.total || 0;
            totalZKVMs++;
        }

        const overallPassRate = totalTests > 0 ? (totalPassed / totalTests * 100).toFixed(1) : 0;

        // Create summary cards
        const cards = [
            {
                title: 'Total ZKVMs',
                value: totalZKVMs,
                label: 'implementations tested',
                class: 'success'
            },
            {
                title: 'Overall Pass Rate',
                value: `${overallPassRate}%`,
                label: `${totalPassed}/${totalTests} tests passed`,
                class: overallPassRate >= 95 ? 'success' : overallPassRate >= 80 ? 'warning' : 'error'
            },
            {
                title: 'Last Test Run',
                value: this.getTimeSinceLastRun(),
                label: 'time since last update',
                class: 'success'
            }
        ];

        cards.forEach(card => {
            const div = document.createElement('div');
            div.className = `summary-card ${card.class}`;
            div.innerHTML = `
                <h3>${card.title}</h3>
                <div class="metric">${card.value}</div>
                <div class="label">${card.label}</div>
            `;
            container.appendChild(div);
        });
    }

    renderComplianceTable() {
        const tbody = document.getElementById('compliance-tbody');
        tbody.innerHTML = '';

        // Handle empty data gracefully
        if (!this.data || !this.data.zkvms || Object.keys(this.data.zkvms).length === 0) {
            const row = document.createElement('tr');
            row.innerHTML = '<td colspan="5" style="text-align: center; color: #666;">No test results available yet</td>';
            tbody.appendChild(row);
            return;
        }

        for (const zkvm in this.data.zkvms) {
            const data = this.data.zkvms[zkvm];
            const row = document.createElement('tr');
            
            // Get ISA from plugin (would be fetched in real implementation)
            const isa = this.getISAForZKVM(zkvm);
            
            // Get ZKVM commit hash (not RISCOF commit)
            const commitHash = data.zkvm_commit || data.commit || 'unknown';
            const commitShort = commitHash === 'unknown' ? 'N/A' : commitHash.substring(0, 8);
            
            row.innerHTML = `
                <td>
                    <a href="zkvm/${zkvm}.html">
                        <strong>${zkvm.toUpperCase()}</strong>
                    </a>
                </td>
                <td>${isa}</td>
                <td>
                    ${commitHash !== 'unknown' ? 
                        `<a href="https://github.com/codygunton/${zkvm}/commit/${commitHash}" target="_blank">${commitShort}</a>` :
                        'N/A'
                    }
                </td>
                <td>
                    <span class="badge ${data.failed === 0 ? 'pass' : 'fail'}">
                        ${data.passed}/${data.total}
                    </span>
                </td>
                <td>
                    <a href="reports/${zkvm}-report.html" class="btn btn-secondary">View</a>
                </td>
            `;
            
            tbody.appendChild(row);
        }
    }

    getISAForZKVM(zkvm) {
        // ISA configurations from each ZKVM's plugin files
        const isaMap = {
            sp1: 'RV32IM',
            openvm: 'RV32IM',
            jolt: 'RV32IM',
            zisk: 'RV64IMA',  // 64-bit with Atomic extension
            risc0: 'RV32IM'
        };
        return isaMap[zkvm] || 'Unknown';
    }

    getTimeSinceLastRun() {
        if (!this.data.last_updated) return 'Never';
        
        const now = new Date();
        const lastUpdate = new Date(this.data.last_updated);
        const diff = now - lastUpdate;
        
        const hours = Math.floor(diff / (1000 * 60 * 60));
        const minutes = Math.floor((diff % (1000 * 60 * 60)) / (1000 * 60));
        
        if (hours > 24) {
            const days = Math.floor(hours / 24);
            return `${days}d ago`;
        } else if (hours > 0) {
            return `${hours}h ${minutes}m`;
        } else {
            return `${minutes}m ago`;
        }
    }

    initChart() {
        const ctx = document.getElementById('trends-chart');
        if (!ctx) return;

        const datasets = [];
        const colors = {
            sp1: { border: 'rgb(255, 99, 132)', background: 'rgba(255, 99, 132, 0.1)' },
            openvm: { border: 'rgb(54, 162, 235)', background: 'rgba(54, 162, 235, 0.1)' },
            jolt: { border: 'rgb(255, 206, 86)', background: 'rgba(255, 206, 86, 0.1)' }
        };

        // Create datasets for each ZKVM
        for (const zkvm in this.historicalData) {
            const history = this.historicalData[zkvm];
            if (history.length === 0) continue;

            datasets.push({
                label: zkvm.toUpperCase(),
                data: history.map(h => ({
                    x: new Date(h.date || h.timestamp),
                    y: h.pass_rate || 0
                })),
                borderColor: colors[zkvm]?.border || 'rgb(75, 192, 192)',
                backgroundColor: colors[zkvm]?.background || 'rgba(75, 192, 192, 0.1)',
                tension: 0.1
            });
        }

        this.chart = new Chart(ctx, {
            type: 'line',
            data: { datasets },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                    title: {
                        display: true,
                        text: 'ZKVM Compliance Trends (Last 90 Days)'
                    },
                    legend: {
                        display: true,
                        position: 'top'
                    }
                },
                scales: {
                    x: {
                        type: 'time',
                        time: {
                            unit: 'day',
                            displayFormats: {
                                day: 'MMM dd'
                            }
                        },
                        title: {
                            display: true,
                            text: 'Date'
                        }
                    },
                    y: {
                        beginAtZero: true,
                        max: 100,
                        title: {
                            display: true,
                            text: 'Pass Rate (%)'
                        }
                    }
                }
            }
        });
    }

    startAutoRefresh() {
        // Refresh data every 5 minutes
        setInterval(() => {
            this.init();
        }, 5 * 60 * 1000);
    }

    showError(message) {
        const container = document.querySelector('.container');
        const errorDiv = document.createElement('div');
        errorDiv.className = 'error-message';
        errorDiv.textContent = message;
        container.prepend(errorDiv);
    }
}

// Initialize dashboard when DOM is loaded
document.addEventListener('DOMContentLoaded', () => {
    new ComplianceDashboard();
});