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
            this.renderDashboard();
            this.startAutoRefresh();
        } catch (error) {
            console.error('Error initializing dashboard:', error);
            this.showError('Failed to load dashboard data');
        }
    }

    async loadData() {
        try {
            // Load current status
            const response = await fetch('data/current/status.json');
            if (!response.ok) throw new Error('Failed to load status data');
            this.data = await response.json();

            // Load historical data for each ZKVM
            for (const zkvm in this.data.zkvms) {
                this.historicalData[zkvm] = await this.loadHistoricalData(zkvm);
            }
        } catch (error) {
            console.error('Error loading data:', error);
            // Use mock data for demonstration
            this.data = this.getMockData();
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
        // Mock data for demonstration
        return {
            zkvms: {
                sp1: {
                    zkvm: "sp1",
                    timestamp: new Date().toISOString(),
                    commit: "fc98075a",
                    passed: 46,
                    failed: 1,
                    total: 47,
                    pass_rate: 97.87
                },
                openvm: {
                    zkvm: "openvm",
                    timestamp: new Date().toISOString(),
                    commit: "a6f77215f",
                    passed: 47,
                    failed: 0,
                    total: 47,
                    pass_rate: 100.00
                },
                jolt: {
                    zkvm: "jolt",
                    timestamp: new Date().toISOString(),
                    commit: "c4b9b060",
                    passed: 44,
                    failed: 3,
                    total: 47,
                    pass_rate: 93.62
                }
            },
            last_updated: new Date().toISOString()
        };
    }

    renderDashboard() {
        this.updateLastUpdated();
        this.renderComplianceTable();
    }

    updateLastUpdated() {
        const element = document.getElementById('last-updated');
        if (this.data.last_updated) {
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

        for (const zkvm in this.data.zkvms) {
            const data = this.data.zkvms[zkvm];
            const row = document.createElement('tr');
            
            // Get ISA from plugin (would be fetched in real implementation)
            const isa = this.getISAForZKVM(zkvm);
            
            row.innerHTML = `
                <td>
                    <a href="zkvm/${zkvm}.html">
                        <strong>${zkvm.toUpperCase()}</strong>
                    </a>
                </td>
                <td>${isa}</td>
                <td>
                    <a href="https://github.com/codygunton/${zkvm}/commit/${data.commit}" target="_blank">
                        ${data.commit.substring(0, 8)}
                    </a>
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
        // In real implementation, this would be fetched from plugin ISA files
        const isaMap = {
            sp1: 'RV32IM',
            openvm: 'RV32IM',
            jolt: 'RV32IM',
            zisk: 'RV32IM'
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