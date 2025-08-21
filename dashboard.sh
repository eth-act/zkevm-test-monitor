#!/bin/bash
# Single script for all dashboard operations

set -e

ACTION="${1:-help}"
ZKVM="${2:-all}"
PORT="${3:-8000}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

function show_help() {
    cat << EOF
Usage: ./dashboard.sh [ACTION] [OPTIONS]

ACTIONS:
  mock     - Create mock data and generate dashboard (quick test)
  serve    - Start web server on port 8000
  build    - Build ZKVM binary (specify: sp1/openvm/jolt/zisk/all)
  test     - Run RISCOF tests (specify: sp1/openvm/jolt/zisk/all)
  update   - Process results and regenerate dashboard
  clean    - Clean all test data

EXAMPLES:
  ./dashboard.sh mock        # Quick test with fake data
  ./dashboard.sh serve       # Start server (port 8000)
  ./dashboard.sh build sp1   # Build SP1 only
  ./dashboard.sh test jolt   # Test Jolt only
  ./dashboard.sh update      # Update dashboard with latest results
EOF
}

function create_mock_data() {
    echo -e "${GREEN}Creating mock test data...${NC}"
    mkdir -p results data/compliance/current
    
    for zkvm in sp1 openvm jolt zisk; do
        if [ -f "configs/zkvm-configs/${zkvm}.json" ]; then
            mkdir -p "results/$zkvm"
            
            # Only create summary.json if it doesn't exist (don't overwrite real results)
            if [ ! -f "results/$zkvm/summary.json" ]; then
                # Use 0/0 for untested ZKVMs
                cat > "results/$zkvm/summary.json" <<EOF
{
  "zkvm": "$zkvm",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "commit": "$(jq -r .commit configs/zkvm-configs/${zkvm}.json 2>/dev/null || echo 'not-tested')",
  "passed": 0,
  "failed": 0,
  "total": 0,
  "pass_rate": 0
}
EOF
                echo "  Created placeholder for $zkvm (not tested yet)"
            else
                echo "  Keeping existing results for $zkvm"
            fi
        fi
    done
    
    update_dashboard
}

function update_dashboard() {
    echo -e "${GREEN}Updating dashboard...${NC}"
    
    # Process results
    ./.github/scripts/process-results.sh results data/compliance
    
    # Generate dashboard
    ./.github/scripts/generate-dashboard.sh data/compliance docs
    
    echo -e "${GREEN}✅ Dashboard updated${NC}"
}

function serve_dashboard() {
    echo -e "${GREEN}Starting server on port $PORT${NC}"
    echo -e "${YELLOW}Access at: http://localhost:$PORT${NC}"
    echo "Press Ctrl+C to stop"
    cd docs && python3 -m http.server $PORT --bind 0.0.0.0
}

function build_zkvm() {
    local zkvm="$1"
    echo -e "${GREEN}Building $zkvm...${NC}"
    
    # Check if Docker build is enabled for this ZKVM
    if [ -f "configs/zkvm-configs/${zkvm}.json" ]; then
        DOCKER_BUILD=$(jq -r '.build.docker // false' "configs/zkvm-configs/${zkvm}.json")
        if [ "$DOCKER_BUILD" = "true" ]; then
            ./.github/scripts/build-zkvm-docker.sh "$zkvm"
        else
            ./.github/scripts/build-zkvm.sh "$zkvm"
        fi
    else
        ./.github/scripts/build-zkvm.sh "$zkvm"
    fi
}

function test_zkvm() {
    local zkvm="$1"
    echo -e "${GREEN}Testing $zkvm...${NC}"
    
    BINARY="artifacts/binaries/${zkvm}-binary"
    if [ ! -f "$BINARY" ]; then
        echo -e "${RED}Binary not found for $zkvm. Skipping. Run: ./dashboard.sh build $zkvm${NC}"
        return 1
    fi
    
    ./.github/scripts/run-riscof-tests.sh "$zkvm" "$BINARY" "results/$zkvm"
}

function clean_all() {
    echo -e "${YELLOW}Cleaning all test data...${NC}"
    rm -rf results/* artifacts/binaries/* build-temp-*
    mkdir -p results  # Keep the results directory
    rm -f data/compliance/current/status.json
    echo '{"zkvms": {}, "last_updated": null}' > data/compliance/current/status.json
    echo -e "${GREEN}✅ Cleaned${NC}"
}

# Main execution
case "$ACTION" in
    mock)
        create_mock_data
        echo -e "${GREEN}Ready! Run: ./dashboard.sh serve${NC}"
        ;;
    serve)
        serve_dashboard
        ;;
    build)
        if [ "$ZKVM" = "all" ]; then
            for z in sp1 openvm jolt zisk; do
                build_zkvm "$z"
            done
        else
            build_zkvm "$ZKVM"
        fi
        ;;
    test)
        if [ "$ZKVM" = "all" ]; then
            for z in sp1 openvm jolt zisk; do
                echo -e "${YELLOW}Testing $z...${NC}"
                test_zkvm "$z" || echo -e "${YELLOW}$z test completed or skipped${NC}"
            done
        else
            test_zkvm "$ZKVM"
        fi
        update_dashboard
        ;;
    update)
        update_dashboard
        ;;
    clean)
        clean_all
        ;;
    *)
        show_help
        ;;
esac