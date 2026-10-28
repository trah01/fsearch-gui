fn main() {
    println!("cargo:rerun-if-changed=VERSION");
    let version = std::fs::read_to_string("VERSION").expect("unable to read VERSION");
    let version = version.trim();
    let parts: Vec<_> = version.split('.').collect();
    assert!(parts.len() == 3 && parts.iter().all(|part| {
        !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit()) && (part.len() == 1 || !part.starts_with('0'))
    }), "VERSION must contain a version such as 0.1.0");
    println!("cargo:rustc-env=FSEARCH_VERSION={version}");
}
