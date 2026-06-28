//! hello-vvm — the smallest possible "annexwyrm-style" service.
//!
//! It speaks minimal HTTP/1.1 over a **Unix domain socket** (no TLS, no TCP
//! port — Caddy terminates TLS and reverse-proxies to this socket, exactly
//! like annexwyrm). It is standard-library-only: no crates, so the Cargo.lock
//! has no dependencies and the Nix build needs nothing fetched.
//!
//! Configuration is by environment variable, set declaratively by the
//! vacationvm app unit:
//!   VVM_HELLO_SOCKET    path of the Unix socket to listen on
//!   VVM_HELLO_GREETING  the headline shown on the page
//!   VVM_HELLO_SECRET    (optional) a secret value injected at runtime; we only
//!                       reveal whether it is present, never its contents.

use std::env;
use std::fs;
use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;

fn main() -> std::io::Result<()> {
    let socket = env::var("VVM_HELLO_SOCKET")
        .unwrap_or_else(|_| "/run/vacationvm-hello-vvm/sock".to_string());
    let greeting =
        env::var("VVM_HELLO_GREETING").unwrap_or_else(|_| "hello from vacationvm".to_string());
    let secret_present = env::var("VVM_HELLO_SECRET").is_ok();

    // Clean up a stale socket left by a previous run so bind() succeeds.
    let path = Path::new(&socket);
    if path.exists() {
        let _ = fs::remove_file(path);
    }

    let listener = UnixListener::bind(&socket)?;
    eprintln!("hello-vvm: listening on {socket}");

    for stream in listener.incoming() {
        match stream {
            Ok(s) => {
                if let Err(e) = handle(s, &greeting, secret_present) {
                    eprintln!("hello-vvm: connection error: {e}");
                }
            }
            Err(e) => eprintln!("hello-vvm: accept error: {e}"),
        }
    }
    Ok(())
}

fn handle(mut stream: UnixStream, greeting: &str, secret_present: bool) -> std::io::Result<()> {
    // Read and discard the request; this service answers everything the same.
    let mut buf = [0u8; 4096];
    let _ = stream.read(&mut buf)?;

    let body = format!(
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>hello-vvm</title>\
         <style>body{{font-family:monospace;background:#f5f0e6;color:#222;\
         max-width:40rem;margin:4rem auto;line-height:1.5}}</style></head><body>\
         <h1>{greeting}</h1>\
         <p>A standard-library-only service, colocated and exposed declaratively \
         by <strong>vacationvm</strong>.</p>\
         <p>runtime secret wired: <strong>{}</strong></p>\
         </body></html>",
        if secret_present { "yes" } else { "no" }
    );
    let response = format!(
        "HTTP/1.1 200 OK\r\n\
         Content-Type: text/html; charset=utf-8\r\n\
         Content-Length: {}\r\n\
         Connection: close\r\n\r\n{}",
        body.len(),
        body
    );
    stream.write_all(response.as_bytes())?;
    stream.flush()
}
