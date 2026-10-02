//! Records the version of the pinned `ere-dockerized` for the ere backend's run records.

fn main() {
    println!("cargo:rerun-if-changed=Cargo.lock");
    let lock = std::fs::read_to_string("Cargo.lock").unwrap_or_default();
    let version = lock
        .split("[[package]]")
        .find(|pkg| pkg.contains("name = \"ere-dockerized\""))
        .and_then(|pkg| pkg.lines().find_map(|line| line.strip_prefix("version = ")))
        .map(|version| version.trim_matches('"').to_string())
        .unwrap_or_else(|| "unknown".to_string());
    println!("cargo:rustc-env=ERE_DOCKERIZED_VERSION={version}");
}
