// Library crate for nettest
// This allows the code to be used as a library from other languages (e.g., Flutter)

pub mod config;
pub mod logger;
pub mod mioserver;
pub mod stream;
pub mod tokio_server;

pub mod client;

// Re-export the main client function for external use
pub use client::client::client_run;

// FFI bindings for Flutter
use std::ffi::{CStr, CString};
use std::os::raw::c_char;

/// FFI wrapper for client_run
/// 
/// # Arguments
/// * `args_json` - JSON string with array of arguments (e.g., `["-c", "--server", "example.com"]`)
/// * `config_json` - JSON string with config (optional, can be null or empty for defaults)
/// 
/// # Returns
/// JSON string with result: `{"success": true}` or `{"error": "error message"}`
/// 
/// # Safety
/// This function is unsafe because it deals with raw pointers.
/// Caller must ensure:
/// - `args_json` is a valid null-terminated C string
/// - `config_json` is either null or a valid null-terminated C string
/// - Returned pointer must be freed using `free_string` function
#[no_mangle]
pub extern "C" fn client_run_ffi(
    args_json: *const c_char,
    config_json: *const c_char,
) -> *mut c_char {
    // Initialize logger if not already initialized (with default level)
    let _ = crate::logger::init_logger(log::LevelFilter::Info);

    // Parse args JSON
    let args: Vec<String> = if args_json.is_null() {
        Vec::new()
    } else {
        let args_str = unsafe {
            match CStr::from_ptr(args_json).to_str() {
                Ok(s) => s,
                Err(e) => {
                    let error = format!("{{\"error\": \"Failed to parse args JSON: {}\"}}", e);
                    return CString::new(error).unwrap().into_raw();
                }
            }
        };
        
        match serde_json::from_str::<Vec<String>>(args_str) {
            Ok(args) => args,
            Err(e) => {
                let error = format!("{{\"error\": \"Invalid args JSON: {}\"}}", e);
                return CString::new(error).unwrap().into_raw();
            }
        }
    };

    // Parse config JSON (optional)
    // For now, we always use default config
    // TODO: Implement JSON deserialization for FileConfig if needed
    let _config_str = if !config_json.is_null() {
        unsafe {
            CStr::from_ptr(config_json).to_str().ok()
        }
    } else {
        None
    };

    // Use default config
    let file_config = crate::config::FileConfig::default();

    // Create tokio runtime and run async function
    let rt = match tokio::runtime::Runtime::new() {
        Ok(rt) => rt,
        Err(e) => {
            let error = format!("{{\"error\": \"Failed to create runtime: {}\"}}", e);
            return CString::new(error).unwrap().into_raw();
        }
    };

    match rt.block_on(client_run(args, Some(file_config))) {
        Ok(_) => {
            CString::new("{\"success\": true}").unwrap().into_raw()
        }
        Err(e) => {
            let error = format!("{{\"error\": \"{}\"}}", e);
            CString::new(error).unwrap().into_raw()
        }
    }
}

/// Free a string that was allocated by Rust and returned to FFI
/// 
/// # Safety
/// This function is unsafe. Caller must ensure:
/// - `ptr` was allocated by Rust (using CString::into_raw)
/// - `ptr` is not null
/// - This function is called exactly once for each allocated string
#[no_mangle]
pub unsafe extern "C" fn free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        let _ = CString::from_raw(ptr);
    }
}

