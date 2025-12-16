// Library crate for nettest
// This allows the code to be used as a library from other languages (e.g., Flutter)

pub mod config;
pub mod logger;
#[cfg(not(target_os = "android"))]
pub mod mioserver;
pub mod stream;
pub mod tokio_server;

pub mod client;

// Re-export the main client function for external use
pub use client::client::client_run;

// FFI bindings for Flutter
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use crate::client::client::client_run_with_progress;
use crate::client::progress::MeasurementProgress;

// Global storage for progress updates (thread-safe)
lazy_static::lazy_static! {
    static ref PROGRESS_STORAGE: Arc<Mutex<Option<MeasurementProgress>>> = Arc::new(Mutex::new(None));
}

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

/// FFI wrapper for client_run with progress support
/// 
/// # Arguments
/// * `args_json` - JSON string with array of arguments
/// * `config_json` - JSON string with config (optional, can be null)
/// 
/// # Returns
/// JSON string with result: `{"success": true}` or `{"error": "error message"}`
/// 
/// Progress updates are stored globally and can be retrieved using `get_progress_ffi()`
/// 
/// # Safety
/// This function is unsafe because it deals with raw pointers.
#[no_mangle]
pub unsafe extern "C" fn client_run_with_progress_ffi(
    args_json: *const c_char,
    _config_json: *const c_char,
) -> *mut c_char {
    // Initialize logger if not already initialized (with default level)
    let _ = crate::logger::init_logger(log::LevelFilter::Info);

    // Parse args JSON
    let args: Vec<String> = if args_json.is_null() {
        Vec::new()
    } else {
        let args_str = match CStr::from_ptr(args_json).to_str() {
            Ok(s) => s,
            Err(e) => {
                let error = format!("{{\"error\": \"Failed to parse args JSON: {}\"}}", e);
                return CString::new(error).unwrap().into_raw();
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

    // Use default config
    let file_config = crate::config::FileConfig::default();

    // Clear previous progress and set initial state
    *PROGRESS_STORAGE.lock().unwrap() = Some(MeasurementProgress {
        phase: "starting".to_string(),
        ping_median_ms: None,
        download_speed_mbps: None,
        upload_speed_mbps: None,
        download_measurements: vec![],
        upload_measurements: vec![],
        progress_percent: 0.0,
        bytes_received: 0,
        bytes_sent: 0,
        thread_count: 0,
        active_threads: 0,
        threads: vec![],
        thread_results: vec![],
    });

    // Create channel for progress updates
    let (sender, receiver) = mpsc::channel::<MeasurementProgress>();
    
    // Spawn thread to receive progress updates and store them globally
    let storage_clone = PROGRESS_STORAGE.clone();
    std::thread::spawn(move || {
        loop {
            match receiver.recv() {
                Ok(progress) => {
                    // Store latest progress
                    if let Ok(mut storage) = storage_clone.lock() {
                        *storage = Some(progress.clone());
                        log::info!("Progress stored: phase={}, percent={}", progress.phase, progress.progress_percent);
                    }
                }
                Err(_) => {
                    log::info!("Progress channel closed");
                    break;
                }
            }
        }
    });

    // Clone sender for use in background thread
    let sender_clone = sender.clone();
    
    // Spawn a thread to run the test in the background
    // This allows the FFI function to return immediately
    std::thread::spawn(move || {
        // Create tokio runtime and run async function in this thread
        let rt = match tokio::runtime::Runtime::new() {
            Ok(rt) => rt,
            Err(e) => {
                log::error!("Failed to create runtime: {}", e);
                // Store error in progress storage
                if let Ok(mut storage) = PROGRESS_STORAGE.lock() {
                    *storage = Some(MeasurementProgress {
                        phase: "error".to_string(),
                        ping_median_ms: None,
                        download_speed_mbps: None,
                        upload_speed_mbps: None,
                        download_measurements: vec![],
                        upload_measurements: vec![],
                        progress_percent: 0.0,
                        bytes_received: 0,
                        bytes_sent: 0,
                        thread_count: 0,
                        active_threads: 0,
                        threads: vec![],
                        thread_results: vec![],
                    });
                }
                return;
            }
        };

        match rt.block_on(client_run_with_progress(args, Some(file_config), Some(sender_clone))) {
            Ok(_) => {
                log::info!("Test completed successfully");
                // Results are already sent through the progress channel, no need to store here
            }
            Err(e) => {
                log::error!("Test failed: {}", e);
                // Store error in progress storage
                if let Ok(mut storage) = PROGRESS_STORAGE.lock() {
                    *storage = Some(MeasurementProgress {
                        phase: "error".to_string(),
                        ping_median_ms: None,
                        download_speed_mbps: None,
                        upload_speed_mbps: None,
                        download_measurements: vec![],
                        upload_measurements: vec![],
                        progress_percent: 0.0,
                        bytes_received: 0,
                        bytes_sent: 0,
                        thread_count: 0,
                        active_threads: 0,
                        threads: vec![],
                        thread_results: vec![],
                    });
                }
            }
        }
    });

    // Return immediately - test is running in background
    CString::new("{\"success\": true, \"message\": \"Test started in background\"}").unwrap().into_raw()
}

/// Get the latest progress update
/// 
/// # Returns
/// JSON string with MeasurementProgress or null if no progress available
/// 
/// # Safety
/// This function is unsafe because it deals with raw pointers.
/// Returned pointer must be freed using `free_string` function
#[no_mangle]
pub unsafe extern "C" fn get_progress_ffi() -> *mut c_char {
    if let Ok(guard) = PROGRESS_STORAGE.lock() {
        if let Some(ref progress) = *guard {
            if let Ok(json) = serde_json::to_string(progress) {
                return CString::new(json).unwrap().into_raw();
            }
        }
    }
    // Return null pointer if no progress
    std::ptr::null_mut()
}

