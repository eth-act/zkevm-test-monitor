#!/usr/bin/env python3
"""
Python test runner for ZKVM testing framework.
Equivalent to test.sh but with Python implementation.
"""

import argparse
import json
import subprocess
import sys
import os
from pathlib import Path
from datetime import datetime
import re


def parse_args():
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(
        description='Run ZKVM tests using RISCOF framework',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --arch                    # Run architecture tests for all ZKVMs
  %(prog)s --extra                   # Run extra tests for all ZKVMs
  %(prog)s --arch zisk spike         # Run architecture tests for specific ZKVMs
        """
    )

    # Mutually exclusive group for test suite selection
    suite_group = parser.add_mutually_exclusive_group(required=True)
    suite_group.add_argument('--arch', action='store_true',
                           help='Run architecture test suite')
    suite_group.add_argument('--extra', action='store_true',
                           help='Run extra test suite')

    parser.add_argument('targets', nargs='*', default=['all'],
                       help='ZKVMs to test (default: all)')

    return parser.parse_args()


def validate_args(args):
    """Validate command line arguments."""
    # Ensure exactly one flag is specified (handled by mutually_exclusive_group)
    if not (args.arch or args.extra):
        print("❌ Error: Must specify either --arch or --extra")
        sys.exit(1)

    # Set test suite based on flags
    if args.arch:
        args.test_suite = 'arch'
    elif args.extra:
        args.test_suite = 'extra'

    return args


def load_config():
    """Load configuration from config.json."""
    config_path = Path('config.json')
    if not config_path.exists():
        print("❌ config.json not found")
        sys.exit(1)

    try:
        with open(config_path) as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        print(f"❌ Invalid JSON in config.json: {e}")
        sys.exit(1)


def check_riscof_setup():
    """Check RISCOF setup and build Docker image."""
    riscof_dir = Path('riscof')
    if not riscof_dir.exists():
        print("❌ riscof directory not found - riscof should be integrated into this repository")
        sys.exit(1)

    print("🔨 Building RISCOF Docker image...")
    try:
        result = subprocess.run([
            'docker', 'build', '-t', 'riscof:latest', '.'
        ], cwd='riscof', capture_output=True, text=True)

        if result.returncode != 0:
            print("❌ Failed to build RISCOF Docker image")
            print(f"Error: {result.stderr}")
            sys.exit(1)
    except subprocess.CalledProcessError as e:
        print(f"❌ Failed to build RISCOF Docker image: {e}")
        sys.exit(1)


def get_zkvms_to_test(targets, config):
    """Get list of ZKVMs to test based on targets."""
    if targets == ['all']:
        return list(config['zkvms'].keys())
    return targets


def check_zkvm_requirements(zkvm):
    """Check if ZKVM has required binary and plugin."""
    binary_path = Path(f'binaries/{zkvm}-binary')
    plugin_path = Path(f'riscof/plugins/{zkvm}')

    if not binary_path.exists():
        print(f"  ⚠️  No binary found, skipping")
        return False

    if not plugin_path.exists():
        print(f"  ⚠️  No plugin found at riscof/plugins/{zkvm}")
        print("  Make sure the riscof symlink points to your riscof repository")
        return False

    return True


def make_binary_executable(zkvm):
    """Make binary executable if possible."""
    binary_path = Path(f'binaries/{zkvm}-binary')
    try:
        binary_path.chmod(0o755)
    except PermissionError:
        # Silently ignore permission errors
        pass


def run_riscof_tests(zkvm, test_suite):
    """Run RISCOF tests for a ZKVM."""
    test_results_dir = Path(f'test-results/{zkvm}')
    test_results_dir.mkdir(parents=True, exist_ok=True)

    # Run Docker container
    docker_cmd = [
        'docker', 'run', '--rm',
        '-e', f'TEST_SUITE={test_suite}',
        '-v', f'{Path.cwd()}/binaries/{zkvm}-binary:/dut/bin/dut-exe',
        '-v', f'{Path.cwd()}/riscof/plugins/{zkvm}:/dut/plugin',
        '-v', f'{Path.cwd()}/test-results/{zkvm}:/riscof/riscof_work',
        'riscof:latest'
    ]

    try:
        # Allow non-zero exit for test failures
        subprocess.run(docker_cmd, check=False)
    except subprocess.CalledProcessError:
        # Tests may fail, this is expected
        pass

    # Copy report with suite suffix
    report_path = test_results_dir / 'report.html'
    suite_report_path = test_results_dir / f'report-{test_suite}.html'

    if report_path.exists():
        import shutil
        shutil.copy2(report_path, suite_report_path)


def parse_test_results(zkvm, test_suite):
    """Parse test results from HTML report."""
    suite_report_path = Path(f'test-results/{zkvm}/report-{test_suite}.html')

    if not suite_report_path.exists():
        print("  ⚠️  Tests ran but no report generated")
        return None

    try:
        with open(suite_report_path) as f:
            content = f.read()
    except Exception as e:
        print(f"  ⚠️  Failed to read report: {e}")
        return None

    # Extract pass/fail counts from HTML
    passed = 0
    failed = 0

    # Try to extract from summary spans first
    passed_match = re.search(r'<span class="passed">(\d+)Passed</span>', content)
    failed_match = re.search(r'<span class="failed">(\d+)Failed</span>', content)

    if passed_match and failed_match:
        passed = int(passed_match.group(1))
        failed = int(failed_match.group(1))
    else:
        # Fall back to counting result rows
        passed = len(re.findall(r'<td class="col-result">Passed</td>', content))
        failed = len(re.findall(r'<td class="col-result">Failed</td>', content))

    total = passed + failed

    return {
        'passed': passed,
        'failed': failed,
        'total': total
    }


def create_summary_json(zkvm, test_suite, results):
    """Create summary JSON file."""
    summary_path = Path(f'test-results/{zkvm}/summary-{test_suite}.json')

    summary = {
        'zkvm': zkvm,
        'suite': test_suite,
        'timestamp': datetime.utcnow().isoformat() + 'Z',
        'passed': results['passed'],
        'failed': results['failed'],
        'total': results['total']
    }

    with open(summary_path, 'w') as f:
        json.dump(summary, f, indent=2)


def update_history(zkvm, test_suite, results, config):
    """Update history file with test results."""
    history_dir = Path('data/history')
    history_dir.mkdir(parents=True, exist_ok=True)

    history_file = history_dir / f'{zkvm}-{test_suite}.json'

    # Get commit information
    try:
        test_monitor_commit = subprocess.check_output(
            ['git', 'rev-parse', 'HEAD'], text=True
        ).strip()[:8]
    except subprocess.CalledProcessError:
        test_monitor_commit = 'unknown'

    # Get ZKVM commit
    commit_file = Path(f'data/commits/{zkvm}.txt')
    if commit_file.exists():
        with open(commit_file) as f:
            zkvm_commit = f.read().strip()
    else:
        zkvm_commit = config.get('zkvms', {}).get(zkvm, {}).get('commit', 'unknown')

    # Get ISA information
    isa_file = Path(f'riscof/plugins/{zkvm}/{zkvm}_isa.yaml')
    isa = 'unknown'
    if isa_file.exists():
        try:
            with open(isa_file) as f:
                content = f.read()
                isa_match = re.search(r'ISA:\s*(\S+)', content)
                if isa_match:
                    isa = isa_match.group(1).lower()
        except Exception:
            pass

    run_date = datetime.utcnow().strftime('%Y-%m-%d')

    new_run = {
        'date': run_date,
        'test_monitor_commit': test_monitor_commit,
        'zkvm_commit': zkvm_commit,
        'isa': isa,
        'suite': test_suite,
        'passed': results['passed'],
        'total': results['total'],
        'notes': ''
    }

    if history_file.exists():
        # Append to existing history
        with open(history_file) as f:
            history = json.load(f)
        history['runs'].append(new_run)
    else:
        # Create new history file
        history = {
            'zkvm': zkvm,
            'suite': test_suite,
            'runs': [new_run]
        }

    with open(history_file, 'w') as f:
        json.dump(history, f, indent=2)


def test_zkvm(zkvm, test_suite, config):
    """Test a single ZKVM."""
    print(f"Testing {zkvm}...")

    if not check_zkvm_requirements(zkvm):
        return

    make_binary_executable(zkvm)
    run_riscof_tests(zkvm, test_suite)

    results = parse_test_results(zkvm, test_suite)
    if results is None:
        return

    create_summary_json(zkvm, test_suite, results)
    update_history(zkvm, test_suite, results, config)

    print(f"  ✅ Tested {zkvm}: {results['passed']}/{results['total']} passed")


def main():
    """Main entry point."""
    args = parse_args()
    args = validate_args(args)

    # Set environment variable for test suite
    os.environ['TEST_SUITE'] = args.test_suite

    config = load_config()
    check_riscof_setup()

    zkvms = get_zkvms_to_test(args.targets, config)

    for zkvm in zkvms:
        test_zkvm(zkvm, args.test_suite, config)


if __name__ == '__main__':
    main()