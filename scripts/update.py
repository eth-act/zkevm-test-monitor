#!/usr/bin/env python3
"""Generate static HTML dashboard with embedded data"""

import json
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
            <strong>Last Updated:</strong> {results.get('last_updated', 'Never')}<br>
            <strong>Test Monitor Commit:</strong> <code>{results.get('test_monitor_commit', 'unknown')}</code><br>
            <strong>Test Suite:</strong> RISC-V Architectural Tests v3.9.1
        </div>
        
        <table>
            <thead>
                <tr>
                    <th>ZKVM</th>
                    <th>ISA</th>
                    <th>Commit</th>
                    <th>Results</th>
                    <th>Pass Rate</th>
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
        pass_rate = f"{(passed/total*100):.1f}%"
        results_class = "pass" if failed == 0 else "fail"
        results_text = f'<span class="{results_class}">{passed}/{total}</span>'
    else:
        pass_rate = "—"
        results_text = '<span class="none">—</span>'
    
    # Report link
    if data.get('has_report'):
        report_link = f'<a href="reports/{zkvm}.html" class="report-btn">View Report</a>'
    else:
        report_link = '<span class="report-btn disabled">No Report</span>'
    
    # Get ISA display
    isa = data.get('isa', 'unknown')
    
    html += f"""
                <tr>
                    <td><strong>{zkvm.upper()}</strong></td>
                    <td><code>{isa}</code></td>
                    <td>{commit_display}</td>
                    <td>{results_text}</td>
                    <td>{pass_rate}</td>
                    <td>{report_link}</td>
                </tr>"""

html += """
            </tbody>
        </table>
        
        <div style="margin-top: 40px; padding-top: 20px; border-top: 1px solid #e0e0e0;">
            <h3>Quick Start</h3>
            <pre style="background: #f8f9fa; padding: 15px; border-radius: 4px; margin: 10px 0;">
# Build all ZKVMs
./run build all

# Test a specific ZKVM  
./run test sp1

# Build and test everything
./run all

# Just update the dashboard
./run update</pre>
            
            <p style="margin-top: 20px; color: #666;">
                This dashboard shows RISC-V compliance test results for various ZKVM implementations.
                Tests are run using <a href="https://github.com/riscv-software-src/riscof">RISCOF</a> 
                against the official RISC-V architectural test suite. Full test reports show individual
                test results and failure details.
            </p>
        </div>
    </div>
</body>
</html>"""

# Write HTML files
with open('index.html', 'w') as f:
    f.write(html)

Path('docs').mkdir(exist_ok=True)
with open('docs/index.html', 'w') as f:
    f.write(html)

print("✅ Dashboard updated")
