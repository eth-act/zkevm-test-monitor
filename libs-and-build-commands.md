(note that we will use Sail as the ref, and we will probably not use Spike for anything since i think ref execution speed is not a big concern).

Name  : SP1
Repo  : github.com/codygunton/sp1.git
Commit: fc98075a
Build : cargo build sp1-perf
Run   : 
docker run --rm \
    -v "$PWD/plugins/sp1:/dut/plugin" \
    -v "$HOME/sp1/target/debug/sp1-perf-executor:/dut/bin/dut-exe" \
    -v "$PWD/results:/riscof/riscof_work" \
    riscof:latest

Name  : OpenVM
Repo  : github.com/codygunton/openvm.git
Commit: a6f77215f
Build : cargo build --release
Run   : 
docker run --rm \
    -v "$PWD/plugins/openvm:/dut/plugin" \
    -v "$HOME/openvm/target/release/cargo-openvm:/dut/bin/dut-exe" \
    -v "$PWD/results:/riscof/riscof_work" \
    riscof:latest

Name  : Jolt
Repo  : github.com/codygunton/jolt
Commit: c4b9b060
Build : cargo build --release -p tracer --bin jolt-emu
Run   :
% docker run --rm \
  -v "$PWD/plugins/jolt:/dut/plugin" \
  -v "$HOME/jolt/target/release/jolt-emu:/dut/bin/dut-exe" \
  -v "$PWD/results:/riscof/riscof_work" \
  riscof:latest


TODO: I will eventually add r0vm, Pico, ZisK and Airbender
