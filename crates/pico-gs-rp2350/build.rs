use std::env;
use std::fs;
use std::path::PathBuf;

fn main() {
    // Copy memory.x to the build output directory so the linker can find it.
    let out = &PathBuf::from(env::var_os("OUT_DIR").unwrap());
    fs::copy("memory.x", out.join("memory.x")).unwrap();
    println!("cargo:rustc-link-search={}", out.display());
    println!("cargo:rerun-if-changed=memory.x");
}
