#!/usr/bin/env python3
"""Generate static HTML dashboard with embedded data"""

import json
import os
import re
import shutil
from pathlib import Path
from datetime import datetime, timezone
import subprocess
import yaml

def get_zkvm_isa(zkvm):
    """Extract ISA definition from RISCOF plugin YAML"""
    try:
        yaml_path = Path(f'riscof/plugins/{zkvm}/{zkvm}_isa.yaml')
        if yaml_path.exists():
            with open(yaml_path) as f:
                data = yaml.safe_load(f)
                # The ISA is typically under hart0 or hart_0
                for key in ['hart0', 'hart_0']:
                    if key in data and 'ISA' in data[key]:
                        isa = data[key]['ISA']
                        # Format as lowercase with extensions (e.g., RV32IM -> rv32im)
                        return isa.lower()
        return "unknown"
    except:
        return "unknown"

def get_test_monitor_commit():
    """Get git commit of this test monitor repo for tracking"""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            capture_output=True, text=True, check=True
        )
        return result.stdout.strip()[:8]
    except:
        return "unknown"

# Load config
with open('config.json') as f:
    config = json.load(f)

# Load or create results
results_file = Path('data/results.json')
if results_file.exists():
    with open(results_file) as f:
        results = json.load(f)
else:
    results = {"zkvms": {}, "last_updated": None, "test_monitor_commit": get_test_monitor_commit()}

# Update results for each ZKVM
for zkvm in config['zkvms']:
    if zkvm not in results['zkvms']:
        results['zkvms'][zkvm] = {}
    
    # Get ISA definition
    results['zkvms'][zkvm]['isa'] = get_zkvm_isa(zkvm)
    
    # Check if nightly updates are configured
    nightly_workflow = Path(f'.github/workflows/nightly-{zkvm}-update.yml')
    results['zkvms'][zkvm]['has_nightly'] = nightly_workflow.exists()
    
    # Keep existing last_run if present, otherwise set to None
    if 'last_run' not in results['zkvms'][zkvm]:
        results['zkvms'][zkvm]['last_run'] = None
    
    # Check binary status
    if Path(f'binaries/{zkvm}-binary').exists():
        results['zkvms'][zkvm]['has_binary'] = True
        results['zkvms'][zkvm]['build_status'] = 'success'
    else:
        results['zkvms'][zkvm]['has_binary'] = False
        results['zkvms'][zkvm]['build_status'] = 'not_built'
    
    # Get actual commit from build (fallback to config)
    commit_file = Path(f'data/commits/{zkvm}.txt')
    if commit_file.exists():
        results['zkvms'][zkvm]['commit'] = commit_file.read_text().strip()
    else:
        results['zkvms'][zkvm]['commit'] = config['zkvms'][zkvm].get('commit', 'unknown')
    
    # Check test results
    summary_file = Path(f'test-results/{zkvm}/summary.json')
    if summary_file.exists():
        try:
            with open(summary_file) as f:
                summary = json.load(f)
                results['zkvms'][zkvm]['passed'] = summary.get('passed', 0)
                results['zkvms'][zkvm]['failed'] = summary.get('failed', 0)
                results['zkvms'][zkvm]['total'] = summary.get('total', 0)
                results['zkvms'][zkvm]['test_status'] = 'completed'
                
                # Update last_run date based on summary file modification time
                mtime = os.path.getmtime(summary_file)
                last_run_date = datetime.fromtimestamp(mtime).strftime('%Y-%m-%d')
                results['zkvms'][zkvm]['last_run'] = last_run_date
        except:
            results['zkvms'][zkvm]['test_status'] = 'error'
    else:
        # Preserve existing test results if no new summary file
        # Only set to 0 if this ZKVM has never been tested
        if 'passed' not in results['zkvms'][zkvm]:
            results['zkvms'][zkvm]['passed'] = 0
            results['zkvms'][zkvm]['failed'] = 0
            results['zkvms'][zkvm]['total'] = 0
            results['zkvms'][zkvm]['test_status'] = 'not_tested'
        # Otherwise, existing results are preserved
    
    # Copy report and CSS if exists
    report_src = Path(f'test-results/{zkvm}/report.html')
    report_dst = Path(f'docs/reports/{zkvm}.html')
    
    if report_src.exists():
        Path('docs/reports').mkdir(parents=True, exist_ok=True)
        shutil.copy(report_src, f'docs/reports/{zkvm}.html')
        # Also copy style.css if it exists
        style_src = Path(f'test-results/{zkvm}/style.css')
        if style_src.exists():
            shutil.copy(style_src, f'docs/reports/style.css')
        results['zkvms'][zkvm]['has_report'] = True
    elif report_dst.exists():
        # Preserve existing report status if no new report
        results['zkvms'][zkvm]['has_report'] = True
    else:
        results['zkvms'][zkvm]['has_report'] = False

# Update timestamp and version
results['last_updated'] = datetime.now(timezone.utc).isoformat()
results['test_monitor_commit'] = get_test_monitor_commit()

# Save results
Path('data').mkdir(exist_ok=True)
with open('data/results.json', 'w') as f:
    json.dump(results, f, indent=2)

# Generate HTML
html = f"""<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>ZKVM Test Monitor</title>
    <style>
        * {{ margin: 0; padding: 0; box-sizing: border-box; }}
        body {{ 
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", monospace;
            padding: 20px;
            background: #f5f5f5;
        }}
        .container {{ 
            max-width: 1200px;
            margin: 0 auto;
            background: white;
            padding: 30px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }}
        h1 {{ 
            margin-bottom: 10px;
            color: #333;
        }}
        .metadata {{
            color: #666;
            font-size: 0.9em;
            margin-bottom: 20px;
            padding-bottom: 20px;
            border-bottom: 1px solid #e0e0e0;
        }}
        table {{ 
            width: 100%;
            border-collapse: collapse;
            margin-top: 20px;
        }}
        th, td {{ 
            text-align: left;
            padding: 12px;
            border-bottom: 1px solid #e0e0e0;
        }}
        th {{ 
            background: #f8f9fa;
            font-weight: 600;
            color: #495057;
        }}
        tr:hover {{ background: #f8f9fa; }}
        .pass {{ color: #28a745; font-weight: 600; }}
        .fail {{ color: #dc3545; font-weight: 600; }}
        .none {{ color: #6c757d; }}
        .badge {{
            padding: 4px 8px;
            border-radius: 4px;
            font-size: 0.85em;
            font-weight: 500;
        }}
        .badge-success {{ background: #d4edda; color: #155724; }}
        .badge-warning {{ background: #fff3cd; color: #856404; }}
        .badge-error {{ background: #f8d7da; color: #721c24; }}
        .badge-info {{ background: #d1ecf1; color: #0c5460; }}
        a {{ color: #007bff; text-decoration: none; }}
        a:hover {{ text-decoration: underline; }}
        .commit-link {{ font-family: monospace; }}
        .report-btn {{
            padding: 4px 12px;
            background: #007bff;
            color: white;
            border-radius: 4px;
            font-size: 0.85em;
            display: inline-block;
        }}
        .report-btn:hover {{
            background: #0056b3;
            text-decoration: none;
        }}
        .report-btn.disabled {{
            background: #6c757d;
            cursor: not-allowed;
        }}
    </style>
</head>
<body>
    <div class="container">
        <h1> RISC-V ZKVM Compliance Test Monitor</h1>
        <div class="metadata">
            <strong>Repository:</strong> <a href="https://github.com/codygunton/zkevm-test-monitor">github.com/codygunton/zkevm-test-monitor</a> (contains steps to reproduce results)<br>
            <strong>Last Updated:</strong> {results.get('last_updated', 'Never')}<br>
            <strong>Test Monitor Commit:</strong> <a href="https://github.com/codygunton/zkevm-test-monitor/commit/{results.get('test_monitor_commit', 'unknown')}" class="commit-link"><code>{results.get('test_monitor_commit', 'unknown')}</code></a><br>
            <strong>Test Suite:</strong> RISC-V Architectural Tests v3.9.1
        </div>
        
        <table>
            <thead>
                <tr>
                    <th>ZKVM</th>
                    <th>ISA</th>
                    <th>CI?</th>
                    <th>Commit</th>
                    <th>Results</th>
                    <th>Last Run</th>
                    <th>Full Report</th>
                </tr>
            </thead>
            <tbody>"""

# Sort ZKVMs alphabetically
for zkvm in sorted(config['zkvms'].keys()):
    data = results['zkvms'].get(zkvm, {})
    
    # Build status badge
    build_status = data.get('build_status', 'not_built')
    build_badge_class = {
        'success': 'badge-success',
        'building': 'badge-warning',
        'failed': 'badge-error',
        'not_built': 'badge-info'
    }.get(build_status, 'badge-info')
    
    # Test status badge  
    test_status = data.get('test_status', 'not_tested')
    test_badge_class = {
        'completed': 'badge-success',
        'running': 'badge-warning',
        'error': 'badge-error',
        'not_tested': 'badge-info'
    }.get(test_status, 'badge-info')
    
    # Commit link (use proper repo URL)
    commit = data.get('commit', 'unknown')
    repo_url = config['zkvms'][zkvm].get('repo_url', f'https://github.com/codygunton/{zkvm}')
    
    if commit != 'unknown' and len(commit) >= 8 and '/' in repo_url:
        # Extract org/repo from URL
        repo_path = repo_url.rstrip('/').replace('https://github.com/', '')
        commit_display = f'<a href="https://github.com/{repo_path}/commit/{commit}" class="commit-link">{commit[:8]}</a>'
    else:
        commit_display = f'<span class="commit-link">{commit}</span>'
    
    # Test results
    passed = data.get('passed', 0)
    failed = data.get('failed', 0)
    total = data.get('total', 0)
    
    if total > 0:
        results_class = "pass" if failed == 0 else "fail"
        results_text = f'<span class="{results_class}">{passed}/{total}</span>'
    else:
        results_text = '<span class="none">—</span>'
    
    # Nightly status
    has_nightly = data.get('has_nightly', False)
    nightly_text = '✓' if has_nightly else '—'
    
    # Last run date
    last_run = data.get('last_run')
    if last_run:
        last_run_text = last_run
    else:
        last_run_text = '—'
    
    # Report link
    if data.get('has_report'):
        report_link = f'<a href="reports/{zkvm}.html" class="report-btn">View Report</a>'
    else:
        report_link = '<span class="report-btn disabled">No Report</span>'
    
    # Get ISA display
    isa = data.get('isa', 'unknown')
    
    html += f"""
                <tr>
                    <td><strong><a href="zkvms/{zkvm}.html">{zkvm.upper()}</a></strong></td>
                    <td><code>{isa}</code></td>
                    <td>{nightly_text}</td>
                    <td>{commit_display}</td>
                    <td>{results_text}</td>
                    <td>{last_run_text}</td>
                    <td>{report_link}</td>
                </tr>"""

html += """
            </tbody>
        </table>
    </div>
</body>
</html>"""

# Write HTML files
with open('index.html', 'w') as f:
    f.write(html)

Path('docs').mkdir(exist_ok=True)
with open('docs/index.html', 'w') as f:
    f.write(html)

# Generate individual ZKVM pages
Path('docs/zkvms').mkdir(parents=True, exist_ok=True)

for zkvm in config['zkvms']:
    # Load history if it exists
    history_file = Path(f'data/history/{zkvm}.json')
    history_runs = []
    if history_file.exists():
        with open(history_file) as f:
            history_data = json.load(f)
            history_runs = history_data.get('runs', [])
    
    # Get repo URL
    repo_url = config['zkvms'][zkvm].get('repo_url', f'https://github.com/codygunton/{zkvm}')
    repo_path = repo_url.rstrip('/').replace('https://github.com/', '')
    
    # Generate ZKVM page HTML
    zkvm_html = f"""<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>{zkvm.upper()} - ZKVM Test Monitor</title>
    <style>
        * {{ margin: 0; padding: 0; box-sizing: border-box; }}
        body {{ 
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", monospace;
            padding: 20px;
            background: #f5f5f5;
        }}
        .container {{ 
            max-width: 1200px;
            margin: 0 auto;
            background: white;
            padding: 30px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }}
        h1 {{ 
            margin-bottom: 10px;
            color: #333;
            display: flex;
            align-items: center;
            gap: 20px;
        }}
        h1 a {{
            font-size: 0.8em;
            font-weight: normal;
        }}
        .back-link {{
            margin-bottom: 20px;
        }}
        .metadata {{
            color: #666;
            font-size: 0.9em;
            margin-bottom: 20px;
            padding-bottom: 20px;
            border-bottom: 1px solid #e0e0e0;
        }}
        table {{ 
            width: 100%;
            border-collapse: collapse;
            margin-top: 20px;
        }}
        th, td {{ 
            text-align: left;
            padding: 12px;
            border-bottom: 1px solid #e0e0e0;
        }}
        th {{ 
            background: #f8f9fa;
            font-weight: 600;
            color: #495057;
        }}
        tr:hover {{ background: #f8f9fa; }}
        .pass {{ color: #28a745; font-weight: 600; }}
        .fail {{ color: #dc3545; font-weight: 600; }}
        .commit-link {{ font-family: monospace; }}
        a {{ color: #007bff; text-decoration: none; }}
        a:hover {{ text-decoration: underline; }}
        .empty-state {{
            text-align: center;
            padding: 60px 20px;
            color: #6c757d;
        }}
    </style>
</head>
<body>
    <div class="container">
        <div class="back-link">
            <a href="../index.html">← Back to Dashboard</a>
        </div>
        <h1>
            {zkvm.upper()}
            <a href="{repo_url}" target="_blank">View Repository →</a>
        </h1>
        <div class="metadata">
            <strong>Repository:</strong> <a href="{repo_url}">{repo_path}</a>
        </div>
        
        <h2>Test Run History</h2>
"""
    
    if history_runs:
        zkvm_html += """
        <table>
            <thead>
                <tr>
                    <th>Run Date</th>
                    <th>Test Monitor Commit</th>
                    <th>ZKVM Commit</th>
                    <th>ISA</th>
                    <th>Results</th>
                    <th>Notes</th>
                </tr>
            </thead>
            <tbody>
"""
        # Sort runs by date in reverse chronological order
        sorted_runs = sorted(history_runs, key=lambda x: x['date'], reverse=True)
        
        for run in sorted_runs:
            # Test monitor commit link
            monitor_commit = run.get('test_monitor_commit', 'unknown')
            if monitor_commit != 'unknown':
                monitor_link = f'<a href="https://github.com/codygunton/zkevm-test-monitor/commit/{monitor_commit}" class="commit-link">{monitor_commit}</a>'
            else:
                monitor_link = f'<span class="commit-link">{monitor_commit}</span>'
            
            # ZKVM commit link
            zkvm_commit = run.get('zkvm_commit', 'unknown')
            if zkvm_commit != 'unknown' and len(zkvm_commit) >= 8:
                zkvm_link = f'<a href="https://github.com/{repo_path}/commit/{zkvm_commit}" class="commit-link">{zkvm_commit[:8]}</a>'
            else:
                zkvm_link = f'<span class="commit-link">{zkvm_commit}</span>'
            
            # Results
            passed = run.get('passed', 0)
            total = run.get('total', 0)
            if total > 0:
                failed = total - passed
                results_class = "pass" if failed == 0 else "fail"
                results_text = f'<span class="{results_class}">{passed}/{total}</span>'
            else:
                results_text = '—'
            
            # Notes field  
            notes = run.get('notes', '')
            notes_html = f'<em>{notes}</em>' if notes else ''
            
            zkvm_html += f"""
                <tr>
                    <td>{run.get('date', 'unknown')}</td>
                    <td>{monitor_link}</td>
                    <td>{zkvm_link}</td>
                    <td><code>{run.get('isa', 'unknown')}</code></td>
                    <td>{results_text}</td>
                    <td>{notes_html}</td>
                </tr>
"""
        
        zkvm_html += """
            </tbody>
        </table>
"""
    else:
        zkvm_html += """
        <div class="empty-state">
            <p>No test history available yet.</p>
            <p>Run tests to start tracking history.</p>
        </div>
"""
    
    zkvm_html += """
    </div>
</body>
</html>"""
    
    # Write ZKVM page
    with open(f'docs/zkvms/{zkvm}.html', 'w') as f:
        f.write(zkvm_html)

print("✅ Dashboard updated")
