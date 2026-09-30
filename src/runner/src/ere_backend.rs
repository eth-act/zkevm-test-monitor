//! ere backend: runs ACT4 ELFs on the official `ere-server-{zkvm}` images of the
//! pinned ere revision (see `ere-dockerized` in Cargo.toml), through
//! `ere-dockerized`. ere builds and runs the zkVM; this module only feeds it ELFs
//! and decides the verdict.
//!
//! One server container serves the whole run: `DockerizedzkVM::setup` switches it
//! to each new ELF. After an error that can leave the server in a bad state, the
//! next test starts a new container. Tests run one at a time, because the
//! container name and port are fixed per zkVM.

use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use anyhow::{Context, anyhow, ensure};
use ere_dockerized::{
    DOCKER_IMAGE_TAG, DockerizedzkVM, DockerizedzkVMConfig, Elf, Input, ProverResource,
    PublicValues, image::server_zkvm_image, prover::Error as EreError, zkVMKind,
};
use serde::Serialize;

use crate::zkvm_backends::{Mode, RunResult, Termination};

/// Registry that ere CI publishes images to.
const IMAGE_REGISTRY: &str = "ghcr.io/eth-act/ere";

/// Time limit on each prove; the other stages use `ere-dockerized`'s defaults.
/// Needed because SP1 v6.6.0 never returns from proving `I-fence-00`: its server
/// logs a fatal task failure, but `prove` does not return an error
/// (eth-act/zkevm-test-monitor#51). Real proves take at most ~35 s.
const PROVE: Duration = Duration::from_secs(120);

/// What was tested: recorded next to the results of each run.
#[derive(Serialize)]
pub struct Provenance {
    /// Short commit of the pinned ere revision; also the image tag.
    pub ere_rev: String,
    /// Version of the pinned `ere-dockerized` crate.
    pub ere_version: String,
    /// Image that ran the tests, by digest.
    pub ere_image: String,
    /// zkVM SDK version that the pinned ere revision uses.
    pub sdk_version: String,
    /// `cpu` or `gpu`.
    pub resource: String,
}

/// Outcome, error and time of one test, for the details file.
#[derive(Serialize)]
struct TestDetail {
    name: String,
    outcome: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
    setup_secs: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    execute_secs: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    prove_secs: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    verify_secs: Option<f64>,
}

/// A test that ran but reported a failure; the server stays usable.
#[derive(Debug)]
struct Verdict(String);

impl std::fmt::Display for Verdict {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Verdict {}

pub struct EreBackend {
    kind: zkVMKind,
    resource: ProverResource,
    /// The running server, kept for the next test; `None` before the first test
    /// and after an error that can leave it broken. The lock also makes tests
    /// run one at a time.
    server: Mutex<Option<DockerizedzkVM>>,
    /// Outcome, error and time of each test, for the details file.
    details: Mutex<Vec<TestDetail>>,
}

impl EreBackend {
    /// Pulls the image of the pinned revision and returns the backend and what
    /// it tests. `zkvm` is `openvm`, `sp1` or `zisk`.
    ///
    /// Call this before any other thread starts: it sets the environment
    /// variables that `ere-dockerized` reads.
    pub fn new(zkvm: &str, gpu: bool) -> anyhow::Result<(Self, Provenance)> {
        let kind: zkVMKind = zkvm
            .parse()
            .map_err(|_| anyhow!("ere has no zkVM named `{zkvm}`"))?;
        ensure!(
            std::env::var_os("ERE_FORCE_REBUILD_DOCKER_IMAGE").is_none(),
            "unset ERE_FORCE_REBUILD_DOCKER_IMAGE: the ere path runs published images only"
        );
        let sdk_version = kind.sdk_version().to_string();

        // SAFETY: called before other threads exist (see above).
        unsafe {
            set_default_env("ERE_IMAGE_REGISTRY", IMAGE_REGISTRY);
            // Named volumes keep the downloaded ZisK proving key and the per-ELF
            // build caches between containers and runs.
            set_default_env(
                "ERE_ZISK_PROVING_KEY_VOLUME",
                &format!("ere-zisk-proving-key-{sdk_version}"),
            );
            set_default_env("ERE_ZISK_CACHE_VOLUME", "ere-zisk-cache");
            set_default_env("ERE_OPENVM_CACHE_VOLUME", "ere-openvm-cache");
        }

        let ere_image = pull_image(kind, gpu)?;
        let provenance = Provenance {
            ere_rev: DOCKER_IMAGE_TAG.to_string(),
            ere_version: env!("ERE_DOCKERIZED_VERSION").to_string(),
            ere_image,
            sdk_version,
            resource: if gpu { "gpu" } else { "cpu" }.to_string(),
        };
        let backend = Self {
            kind,
            resource: if gpu { ProverResource::Gpu } else { ProverResource::Cpu },
            server: Mutex::new(None),
            details: Mutex::new(Vec::new()),
        };
        Ok((backend, provenance))
    }

    pub fn run_elf(&self, elf_path: &Path, mode: Mode, start: Instant) -> RunResult {
        let mut server = self.server.lock().unwrap_or_else(|err| err.into_inner());
        let mut detail = TestDetail {
            name: elf_path
                .file_stem()
                .and_then(|n| n.to_str())
                .unwrap_or("unknown")
                .to_string(),
            outcome: "passed",
            error: None,
            setup_secs: 0.0,
            execute_secs: None,
            prove_secs: None,
            verify_secs: None,
        };

        let mut result = RunResult {
            passed: false,
            exit_code: None,
            duration: Duration::ZERO,
            prove_duration: None,
            proof_written: false,
            prove_status: None,
            verify_status: None,
            termination: Termination::HostError,
            detail: None,
        };

        if let Err((stage, err)) = self.run_stages(&mut server, elf_path, mode, &mut detail, &mut result)
        {
            detail.outcome = stage;
            detail.error = Some(format!("{err:#}"));
            eprintln!("    {}: {stage}: {err:#}", detail.name);
        }
        result.detail = detail.error.clone();
        result.duration = start.elapsed();
        self.details.lock().unwrap_or_else(|err| err.into_inner()).push(detail);
        result
    }

    /// Runs setup, execute, prove and verify up to `mode`, and stops at the
    /// first stage that fails. Returns the failed stage's outcome name.
    fn run_stages(
        &self,
        server: &mut Option<DockerizedzkVM>,
        elf_path: &Path,
        mode: Mode,
        detail: &mut TestDetail,
        result: &mut RunResult,
    ) -> Result<(), (&'static str, anyhow::Error)> {
        let elf = std::fs::read(elf_path)
            .with_context(|| format!("failed to read {}", elf_path.display()))
            .map_err(|err| ("failed", err))?;

        // Setup: switch the running server to this ELF, or start one.
        let started = Instant::now();
        let setup = match server.take() {
            Some(mut zkvm) => zkvm.setup(Elf(elf)).map(|()| zkvm),
            None => {
                let config = DockerizedzkVMConfig {
                    prove_timeout: Some(PROVE),
                    ..Default::default()
                };
                DockerizedzkVM::new(self.kind, Elf(elf), self.resource.clone(), config)
                    .map_err(Into::into)
            }
        };
        detail.setup_secs = started.elapsed().as_secs_f64();
        let zkvm = setup.map_err(|err| ("failed", err.context("setup")))?;

        let input = Input::new();
        let outcome = (|| {
            let started = Instant::now();
            let executed = zkvm.execute(&input);
            detail.execute_secs = Some(started.elapsed().as_secs_f64());
            result.termination = execution_termination(&executed);
            let (public_values, _) = executed.map_err(|err| ("failed", err))?;
            self.verdict(&public_values).map_err(|err| ("failed", err))?;
            result.passed = true;
            if mode == Mode::Execute {
                return Ok(());
            }

            let started = Instant::now();
            let proved = zkvm.prove(&input);
            let secs = started.elapsed();
            detail.prove_secs = Some(secs.as_secs_f64());
            result.prove_duration = Some(secs);
            result.prove_status = Some("failed".to_string());
            let (public_values, proof, _) = proved.map_err(|err| ("prove_failed", err))?;
            self.verdict(&public_values)
                .map_err(|err| ("prove_failed", err.context("proof public values")))?;
            result.prove_status = Some("success".to_string());
            result.proof_written = true;
            if mode == Mode::Prove {
                return Ok(());
            }

            let started = Instant::now();
            let verified = zkvm.verify(&proof);
            detail.verify_secs = Some(started.elapsed().as_secs_f64());
            result.verify_status = Some("failed".to_string());
            let public_values = verified.map_err(|err| ("verify_failed", err))?;
            self.verdict(&public_values)
                .map_err(|err| ("verify_failed", err.context("verified public values")))?;
            result.verify_status = Some("success".to_string());
            Ok(())
        })();

        // Keep the server for the next test unless the error can mean that it
        // is broken. A zkVM error (e.g. a guest that exits non-zero) is a
        // normal test failure and leaves the server healthy.
        let keep = match &outcome {
            Ok(()) => true,
            Err((_, err)) => {
                err.downcast_ref::<Verdict>().is_some()
                    || matches!(err.downcast_ref::<EreError>(), Some(EreError::zkVM(_)))
            }
        };
        if keep {
            *server = Some(zkvm);
        }
        outcome
    }

    /// Decides whether a stage passed from the public values it returned.
    ///
    /// Every zkVM's ACT4 halt macros write `PASS` or `FAIL` to public output 0
    /// (zkvms/<zkvm>/isa-configs/*/rvmodel_macros.h), so the verdict does not
    /// depend on how ere or the zkVM treats the exit code, and it is committed in
    /// the proof.
    fn verdict(&self, public_values: &PublicValues) -> anyhow::Result<()> {
        if public_values.starts_with(b"PASS") {
            return Ok(());
        }
        let marker = &public_values[..public_values.len().min(4)];
        let shown = if marker == b"FAIL" {
            "FAIL".to_string()
        } else {
            format!("0x{}", String::from_iter(marker.iter().map(|b| format!("{b:02x}"))))
        };
        Err(Verdict(format!("test reported {shown} in public output 0, not PASS")).into())
    }

    /// Writes the per-test details and the provenance of this run to
    /// `<dir>/details-act4-<label>.json` and `<dir>/ere-act4-<label>.json`.
    pub fn finish(&self, dir: &Path, label: &str, provenance: &Provenance) -> anyhow::Result<()> {
        // Dropping the server removes its container.
        *self.server.lock().unwrap_or_else(|err| err.into_inner()) = None;
        let details = self.details.lock().unwrap_or_else(|err| err.into_inner());
        write_json(&dir.join(format!("details-act4-{label}.json")), &*details)?;
        write_json(&dir.join(format!("ere-act4-{label}.json")), provenance)
    }
}

/// How the guest terminated, from ere's execution result. Until execution
/// returns, the result stays a host error: an unreadable ELF, a failed setup or
/// a Docker or transport error never counts as a guest termination.
/// - The `FAIL` marker in public output 0, or a zkVM error (for example a guest
///   that exits non-zero), is an abnormal termination without a code.
/// - Other public values are a successful termination; the verdict still needs
///   `PASS` (`EreBackend::verdict`).
/// - Any other error is a host error.
fn execution_termination<T>(executed: &anyhow::Result<(PublicValues, T)>) -> Termination {
    match executed {
        Ok((public_values, _)) if public_values.starts_with(b"FAIL") => Termination::Failure { code: None },
        Ok(_) => Termination::Success,
        Err(err) if matches!(err.downcast_ref::<EreError>(), Some(EreError::zkVM(_))) => {
            Termination::Failure { code: None }
        }
        Err(_) => Termination::HostError,
    }
}

/// Sets `key` to `value` unless the user set it already.
///
/// # Safety
///
/// No other thread may read or write the environment at the same time.
unsafe fn set_default_env(key: &str, value: &str) {
    if std::env::var_os(key).is_none() {
        unsafe { std::env::set_var(key, value) };
    }
}

/// Pulls the server image of the pinned revision, so `ere-dockerized` never
/// builds one locally, and returns its digest.
fn pull_image(kind: zkVMKind, gpu: bool) -> anyhow::Result<String> {
    let image = server_zkvm_image(kind, gpu);
    let status = Command::new("docker")
        .args(["pull", "--quiet", &image])
        .stdout(Stdio::null())
        .status()
        .context("failed to run docker")?;
    ensure!(
        status.success(),
        "no published image {image}; ere publishes images for commits on master and release/*"
    );
    let output = Command::new("docker")
        .args(["image", "inspect", "--format", "{{index .RepoDigests 0}}", &image])
        .output()
        .context("failed to run docker")?;
    ensure!(output.status.success(), "failed to inspect {image}");
    Ok(String::from_utf8(output.stdout)?.trim().to_string())
}

fn write_json(path: &Path, value: &impl Serialize) -> anyhow::Result<()> {
    let json = serde_json::to_string_pretty(value)?;
    std::fs::write(path, format!("{json}\n"))
        .with_context(|| format!("failed to write {}", path.display()))
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;
    use crate::runner::{self, Suite};

    fn executed(result: anyhow::Result<&[u8]>) -> anyhow::Result<(PublicValues, Duration)> {
        result.map(|bytes| (PublicValues(bytes.to_vec()), Duration::ZERO))
    }

    #[test]
    fn classifies_the_execution() {
        let failure = Termination::Failure { code: None };
        assert_eq!(execution_termination(&executed(Ok(b"PASS"))), Termination::Success);
        assert_eq!(execution_termination(&executed(Ok(b"\0\0\0\0"))), Termination::Success);
        assert_eq!(execution_termination(&executed(Ok(b"FAIL"))), failure);
        let guest = anyhow::Error::from(EreError::zkVM("guest exited with code 1".to_owned()));
        assert_eq!(execution_termination(&executed(Err(guest))), failure);
        let transport = anyhow!("RPC to zkVM server error");
        assert_eq!(execution_termination(&executed(Err(transport))), Termination::HostError);
    }

    /// An ELF that cannot be read never starts a guest, so it cannot pass a
    /// test that expects an abnormal termination. No Docker is needed: the run
    /// stops before setup.
    #[test]
    fn unreadable_elf_is_a_host_error() {
        let dir = tempfile::tempdir().unwrap();
        let elf = dir.path().join("t.elf");
        std::os::unix::fs::symlink(dir.path().join("missing"), &elf).unwrap();
        std::fs::write(dir.path().join("t.outcome"), "fail\n").unwrap();
        let ere = EreBackend {
            kind: "sp1".parse().unwrap(),
            resource: ProverResource::Cpu,
            server: Mutex::new(None),
            details: Mutex::new(Vec::new()),
        };
        let r = runner::run_one_with("ere-sp1", Suite::Isa, &elf, |elf| ere.run_elf(elf, Mode::Execute, Instant::now()));
        assert_eq!(r.termination, Termination::HostError);
        assert!(!r.passed);
        assert!(r.detail.unwrap().contains("failed to read"), "detail");
    }
}
