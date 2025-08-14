// ZKVM Detail Page JavaScript
document.addEventListener('DOMContentLoaded', () => {
    const zkvm = window.zkvmName;
    const data = window.zkvmData;
    
    // Populate current data in the table
    const tbody = document.getElementById(`history-tbody-${zkvm}`);
    if (tbody && data) {
        // Add current result as the first row
        const row = document.createElement('tr');
        const date = new Date(data.timestamp);
        row.innerHTML = `
            <td>${date.toLocaleDateString()}</td>
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
            <td>${data.pass_rate.toFixed(1)}%</td>
        `;
        tbody.appendChild(row);
        
        // TODO: Load historical data from archives when available
        // For now, just show the current result
    }
});