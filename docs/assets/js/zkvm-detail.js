// ZKVM detail page JavaScript
class ZKVMDetail {
    constructor() {
        this.zkvmName = window.zkvmName;
        this.zkvmData = window.zkvmData;
        this.historicalData = [];
        this.init();
    }

    async init() {
        try {
            await this.loadHistoricalData();
            this.renderCurrentStatus();
            this.renderHistoryChart();
            this.renderHistoryTable();
        } catch (error) {
            console.error('Error initializing ZKVM detail page:', error);
        }
    }

    async loadHistoricalData() {
        // Load historical data for this ZKVM
        // In real implementation, this would fetch from data/history/
        const currentDate = new Date();
        this.historicalData = [];
        
        // Generate mock historical data for demonstration
        for (let i = 0; i < 90; i += 7) {
            const date = new Date(currentDate);
            date.setDate(date.getDate() - i);
            
            this.historicalData.push({
                date: date.toISOString(),
                commit: this.zkvmData.commit,
                passed: this.zkvmData.passed - Math.floor(Math.random() * 3),
                failed: this.zkvmData.failed + Math.floor(Math.random() * 3),
                total: this.zkvmData.total,
                pass_rate: ((this.zkvmData.passed - Math.floor(Math.random() * 3)) / this.zkvmData.total * 100).toFixed(2)
            });
        }
    }

    renderCurrentStatus() {
        const container = document.getElementById(`current-${this.zkvmName}`);
        if (!container) return;

        container.innerHTML = `
            <div class="metrics">
                <div class="metric-item">
                    <div class="metric-value">${this.zkvmData.passed}</div>
                    <div class="metric-label">Tests Passed</div>
                </div>
                <div class="metric-item">
                    <div class="metric-value">${this.zkvmData.failed}</div>
                    <div class="metric-label">Tests Failed</div>
                </div>
                <div class="metric-item">
                    <div class="metric-value">${this.zkvmData.pass_rate.toFixed(1)}%</div>
                    <div class="metric-label">Pass Rate</div>
                </div>
                <div class="metric-item">
                    <div class="metric-value">${this.zkvmData.commit.substring(0, 8)}</div>
                    <div class="metric-label">Commit</div>
                </div>
            </div>
            <p style="margin-top: 15px; color: #718096;">
                Last tested: ${new Date(this.zkvmData.timestamp).toLocaleString()}
            </p>
        `;
    }

    renderHistoryChart() {
        const ctx = document.getElementById(`history-chart-${this.zkvmName}`);
        if (!ctx) return;

        const data = this.historicalData.reverse();
        
        new Chart(ctx, {
            type: 'line',
            data: {
                labels: data.map(d => new Date(d.date).toLocaleDateString()),
                datasets: [{
                    label: 'Pass Rate (%)',
                    data: data.map(d => parseFloat(d.pass_rate)),
                    borderColor: 'rgb(102, 126, 234)',
                    backgroundColor: 'rgba(102, 126, 234, 0.1)',
                    tension: 0.1
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                    title: {
                        display: false
                    },
                    legend: {
                        display: false
                    }
                },
                scales: {
                    y: {
                        beginAtZero: true,
                        max: 100,
                        title: {
                            display: true,
                            text: 'Pass Rate (%)'
                        }
                    },
                    x: {
                        title: {
                            display: true,
                            text: 'Date'
                        }
                    }
                }
            }
        });
    }

    renderHistoryTable() {
        const container = document.getElementById(`history-table-${this.zkvmName}`);
        if (!container) return;

        let tableHTML = `
            <table>
                <thead>
                    <tr>
                        <th>Date</th>
                        <th>Commit</th>
                        <th>Results</th>
                        <th>Pass Rate</th>
                        <th>Report</th>
                    </tr>
                </thead>
                <tbody>
        `;

        this.historicalData.slice(0, 10).forEach(entry => {
            const date = new Date(entry.date);
            tableHTML += `
                <tr>
                    <td>${date.toLocaleDateString()}</td>
                    <td>
                        <a href="https://github.com/codygunton/${this.zkvmName}/commit/${entry.commit}" target="_blank">
                            ${entry.commit.substring(0, 8)}
                        </a>
                    </td>
                    <td>
                        <span class="badge ${entry.failed === 0 ? 'pass' : 'fail'}">
                            ${entry.passed}/${entry.total}
                        </span>
                    </td>
                    <td>${entry.pass_rate}%</td>
                    <td>
                        <a href="../data/archives/${this.zkvmName}/report-${date.toISOString().slice(0, 10)}.html" 
                           target="_blank" class="btn btn-secondary">View</a>
                    </td>
                </tr>
            `;
        });

        tableHTML += `
                </tbody>
            </table>
        `;

        container.innerHTML = tableHTML;
    }
}

// Initialize when DOM is loaded
document.addEventListener('DOMContentLoaded', () => {
    if (window.zkvmName && window.zkvmData) {
        new ZKVMDetail();
    }
});