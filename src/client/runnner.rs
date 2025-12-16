use std::{
    net::SocketAddr,
    sync::{Arc, Barrier},
    thread,
};

use std::sync::mpsc;
use std::sync::Mutex;

use log::debug;

use crate::client::{
    calculator::{
        calculate_download_speed_from_stats_silent, calculate_upload_speed_from_stats_silent,
    },
    client::{ClientConfig, Measurement, SharedStats},
    control_server::MeasurementSaver,
    print::printer::{print_float_result, print_test_result},
    progress::{MeasurementProgress, ThreadStates},
    state::TestState,
};

pub async fn run_threads(
    config: ClientConfig,
    stats: Arc<Mutex<SharedStats>>,
) -> Result<Vec<Measurement>, anyhow::Error> {
    run_threads_with_progress(config, stats, None).await
}

pub async fn run_threads_with_progress(
    config: ClientConfig,
    stats: Arc<Mutex<SharedStats>>,
    progress_sender: Option<mpsc::Sender<MeasurementProgress>>,
) -> Result<Vec<Measurement>, anyhow::Error> {
    let config_clone = config.clone();
    let barrier = Arc::new(Barrier::new(config.thread_count));
    let mut thread_handles = vec![];
    let ping_median = Arc::new(Mutex::new(None::<u64>));
    let download_speed = Arc::new(Mutex::new(None::<f64>));
    let upload_speed = Arc::new(Mutex::new(None::<f64>));
    
    // Thread states for progress reporting
    let thread_states: ThreadStates = Arc::new(Mutex::new(vec![None; config.thread_count]));
    
    // Wrap sender in Arc<Mutex<Option<>>> so threads can access it
    let progress_sender_arc: Arc<Mutex<Option<mpsc::Sender<MeasurementProgress>>>> = 
        Arc::new(Mutex::new(progress_sender));

    // Get server address (IP or hostname)
    let server_addr = config.server.clone().unwrap();

    // Resolve IP if it's a hostname
    let ip = if crate::client::control_server::servers::is_ip_address(&server_addr) {
        server_addr.clone()
    } else {
        match crate::client::control_server::servers::resolve_ip_from_web_address(&server_addr) {
            Ok(ip) => ip,
            Err(_) => server_addr.clone(), // Fallback to original if resolution fails
        }
    };

    debug!("Resolved IP: {}", ip);

    let addr = if !config.use_tls {
        format!("{}:{}", ip, config.port).parse::<SocketAddr>()?
    } else {
        format!("{}:{}", ip, config.tls_port).parse::<SocketAddr>()?
    };

    // Helper function to send progress update (called from threads)
    let send_progress = |phase: &str, progress: f64, 
                         stats: &Arc<Mutex<SharedStats>>,
                         ping_median: &Arc<Mutex<Option<u64>>>,
                         download_speed: &Arc<Mutex<Option<f64>>>,
                         upload_speed: &Arc<Mutex<Option<f64>>>,
                         thread_states: &ThreadStates,
                         thread_count: usize,
                         sender_arc: &Arc<Mutex<Option<mpsc::Sender<MeasurementProgress>>>>| {
        if let Ok(sender_guard) = sender_arc.lock() {
            if let Some(ref sender) = *sender_guard {
                let stats_guard = stats.lock().unwrap();
                let ping_val = *ping_median.lock().unwrap();
                let dl_speed = *download_speed.lock().unwrap();
                let ul_speed = *upload_speed.lock().unwrap();
                let thread_states_guard = thread_states.lock().unwrap();
                
                let mut total_bytes_received = 0u64;
                let mut total_bytes_sent = 0u64;
                let mut active_count = 0;
                let mut thread_infos = Vec::new();
                
                for (thread_id, state_opt) in thread_states_guard.iter().enumerate() {
                    if let Some(ref state) = state_opt {
                        if !state.failed {
                            active_count += 1;
                            total_bytes_received += state.bytes_received;
                            total_bytes_sent += state.bytes_sent;
                        }
                        
                        // Add thread info with measurements
                        thread_infos.push(crate::client::progress::ThreadInfo {
                            thread_id,
                            phase: MeasurementProgress::from_phase(&state.phase),
                            bytes_received: state.bytes_received,
                            bytes_sent: state.bytes_sent,
                            failed: state.failed,
                            download_measurements: state.download_measurements.iter().cloned().collect(),
                            upload_measurements: state.upload_measurements.iter().cloned().collect(),
                        });
                    } else {
                        // Thread not initialized yet
                        thread_infos.push(crate::client::progress::ThreadInfo {
                            thread_id,
                            phase: "waiting".to_string(),
                            bytes_received: 0,
                            bytes_sent: 0,
                            failed: false,
                            download_measurements: vec![],
                            upload_measurements: vec![],
                        });
                    }
                }
                
                let progress_update = MeasurementProgress {
                    phase: phase.to_string(),
                    ping_median_ms: ping_val.map(|v| v as f64 / 1_000_000.0),
                    download_speed_mbps: dl_speed.map(|v| v / 1_000_000.0), // Convert to Mbps
                    upload_speed_mbps: ul_speed.map(|v| v / 1_000_000.0),
                    download_measurements: stats_guard.download_measurements.clone(),
                    upload_measurements: stats_guard.upload_measurements.clone(),
                    progress_percent: progress,
                    bytes_received: total_bytes_received,
                    bytes_sent: total_bytes_sent,
                    thread_count,
                    active_threads: active_count,
                    threads: thread_infos,
                    thread_results: vec![], // Empty during progress updates
                };
                
                match sender.send(progress_update.clone()) {
                    Ok(_) => {
                        log::debug!("Progress sent: phase={}, percent={}", progress_update.phase, progress_update.progress_percent);
                    }
                    Err(e) => {
                        log::warn!("Failed to send progress: {}", e);
                    }
                }
            } else {
                log::debug!("No progress sender available");
            }
        }
    };

    for i in 0..config.thread_count {
        let barrier = Arc::clone(&barrier);
        let stats = Arc::clone(&stats);
        let ping_median_clone = Arc::clone(&ping_median);
        let download_speed_clone = Arc::clone(&download_speed);
        let upload_speed_clone = Arc::clone(&upload_speed);
        let thread_states_clone = Arc::clone(&thread_states);
        let progress_sender_clone = Arc::clone(&progress_sender_arc);
        let config_clone_inner = config.clone();
        thread_handles.push(thread::spawn(move || {
            let mut state =
                match TestState::new_with_thread_tracking(
                    addr, 
                    config_clone_inner.use_tls, 
                    config_clone_inner.use_websocket, 
                    i, 
                    None, 
                    None,
                    Some(thread_states_clone.clone()),
                    Some(i),
                    Some(progress_sender_clone.clone()),
                ) {
                    Ok(state) => state,
                    Err(e) => {
                        debug!("TestState error: {:?} token: {}", e, i);
                        return Err(e);
                    }
                };

            let greeting = state.process_greeting();
            match greeting {
                Ok(_) => {}
                Err(e) => {
                    debug!("Greeting error: {:?} token: {}", e, i);
                }
            }
            
            // Thread state is automatically updated in process_phase
            barrier.wait();
            
            // Send progress after greeting
            send_progress("greeting", 10.0, &stats, &ping_median_clone, &download_speed_clone, 
                         &upload_speed_clone, &thread_states_clone, config_clone_inner.thread_count,
                         &progress_sender_clone);
            
            state.run_get_chunks().unwrap();
            
            // Thread state is automatically updated in process_phase
            barrier.wait();
            
            // Send progress after init_download
            send_progress("init_download", 20.0, &stats, &ping_median_clone, &download_speed_clone, 
                         &upload_speed_clone, &thread_states_clone, config_clone_inner.thread_count,
                         &progress_sender_clone);

            if i == 0 {
                state.run_ping().unwrap();
                let median = state.measurement_state().ping_median.unwrap();
                let ping_ms = median as f64 / 1000000.0;

                *ping_median_clone.lock().unwrap() = Some(median);

                if config_clone_inner.raw_output {
                    print!("{:.2}", ping_ms);
                } else {
                    print_float_result("Ping Median", "ms", Some(ping_ms));
                }
            }
            
            // Thread state is automatically updated in process_phase
            barrier.wait();
            
            // Send progress after ping
            send_progress("ping", 30.0, &stats, &ping_median_clone, &download_speed_clone, 
                         &upload_speed_clone, &thread_states_clone, config_clone_inner.thread_count,
                         &progress_sender_clone);
            
            state.run_get_time().unwrap();
            {
                let mut stats = stats.lock().unwrap();
                stats.download_measurements.push(
                    state
                        .measurement_state()
                        .download_measurements
                        .iter()
                        .cloned()
                        .collect(),
                );
            }
            
            // Thread state is automatically updated in process_phase
            barrier.wait();
            
            // Send progress after download test
            send_progress("download", 60.0, &stats, &ping_median_clone, &download_speed_clone, 
                         &upload_speed_clone, &thread_states_clone, config_clone_inner.thread_count,
                         &progress_sender_clone);

            if i == 0 {
                let stats_guard = stats.lock().unwrap();
                let speed =
                    calculate_download_speed_from_stats_silent(&stats_guard.download_measurements);

                // Save download speed for later use
                *download_speed_clone.lock().unwrap() = Some(speed.2); // speed.1 is Gbps

                if config_clone_inner.raw_output {
                    print!("/{:.2}", speed.1); // speed.1 is Gbps
                } else {
                    print_test_result("Download Test", "Completed", Some(speed));
                }
            }

            barrier.wait();
            
            // Send progress after download speed calculated
            send_progress("download", 70.0, &stats, &ping_median_clone, &download_speed_clone, 
                         &upload_speed_clone, &thread_states_clone, config_clone_inner.thread_count,
                         &progress_sender_clone);

            state.run_perf_test().unwrap();
            {
                let mut stats = stats.lock().unwrap();
                stats.upload_measurements.push(
                    state
                        .measurement_state()
                        .upload_measurements
                        .iter()
                        .cloned()
                        .collect(),
                );
            }
            
            // Thread state is automatically updated in process_phase
            barrier.wait();
            
            // Send progress after upload test
            send_progress("upload", 85.0, &stats, &ping_median_clone, &download_speed_clone, 
                         &upload_speed_clone, &thread_states_clone, config_clone_inner.thread_count,
                         &progress_sender_clone);

            if i == 0 {
                let stats_guard = stats.lock().unwrap();
                let speed =
                    calculate_upload_speed_from_stats_silent(&stats_guard.upload_measurements);

                // Save upload speed for later use
                *upload_speed_clone.lock().unwrap() = Some(speed.2); // speed.1 is Gbps

                if config_clone_inner.raw_output {
                    println!("/{:.2}", speed.1); // speed.1 is Gbps, println! for line break
                } else {
                    print_test_result("Upload Test", "Completed", Some(speed));
                }
            }

            barrier.wait();
            
            // Send progress after upload speed calculated
            send_progress("upload", 90.0, &stats, &ping_median_clone, &download_speed_clone, 
                         &upload_speed_clone, &thread_states_clone, config_clone_inner.thread_count,
                         &progress_sender_clone);

            if config_clone_inner.save_results && config_clone_inner.signed_result {
                state.run_signed_result().unwrap();
                barrier.wait();
                
                // Send progress after signed result
                send_progress("signed_result", 95.0, &stats, &ping_median_clone, &download_speed_clone, 
                             &upload_speed_clone, &thread_states_clone, config_clone_inner.thread_count,
                             &progress_sender_clone);
            }

            let result: Measurement = Measurement {
                thread_id: i,
                failed: state.measurement_state().failed,
                measurements: state
                    .measurement_state()
                    .download_measurements
                    .iter()
                    .cloned()
                    .collect(),
                upload_measurements: state
                    .measurement_state()
                    .upload_measurements
                    .iter()
                    .cloned()
                    .collect(),
                envelope: state.measurement_state().envelope.clone(),
            };
            Ok(result)
        }));
    }

    let states: Vec<Measurement> = thread_handles
        .into_iter()
        .map(|h| h.join().unwrap())
        .filter(|s| s.is_ok())
        .map(|s| s.unwrap())
        .collect();

    // Send final progress with detailed thread results
    if let Ok(sender_guard) = progress_sender_arc.lock() {
        if let Some(ref sender) = *sender_guard {
            let stats_guard = stats.lock().unwrap();
            let ping_val = *ping_median.lock().unwrap();
            let dl_speed = *download_speed.lock().unwrap();
            let ul_speed = *upload_speed.lock().unwrap();
            
            // Collect detailed thread results
            let thread_results: Vec<crate::client::progress::ThreadResult> = states
                .iter()
                .map(|m| {
                    let total_bytes_received: u64 = m.measurements.iter().map(|(_, bytes)| bytes).sum();
                    let total_bytes_sent: u64 = m.upload_measurements.iter().map(|(_, bytes)| bytes).sum();
                    
                    crate::client::progress::ThreadResult {
                        thread_id: m.thread_id,
                        failed: m.failed,
                        download_measurements: m.measurements.clone(),
                        upload_measurements: m.upload_measurements.clone(),
                        total_bytes_received,
                        total_bytes_sent,
                        download_samples: m.measurements.len(),
                        upload_samples: m.upload_measurements.len(),
                        envelope: m.envelope.clone(),
                    }
                })
                .collect();
            
            // Get final thread states for display
            let thread_states_guard = thread_states.lock().unwrap();
            let mut thread_infos = Vec::new();
            for (thread_id, state_opt) in thread_states_guard.iter().enumerate() {
                if let Some(ref state) = state_opt {
                    thread_infos.push(crate::client::progress::ThreadInfo {
                        thread_id,
                        phase: MeasurementProgress::from_phase(&state.phase),
                        bytes_received: state.bytes_received,
                        bytes_sent: state.bytes_sent,
                        failed: state.failed,
                        download_measurements: state.download_measurements.iter().cloned().collect(),
                        upload_measurements: state.upload_measurements.iter().cloned().collect(),
                    });
                } else {
                    thread_infos.push(crate::client::progress::ThreadInfo {
                        thread_id,
                        phase: "completed".to_string(),
                        bytes_received: 0,
                        bytes_sent: 0,
                        failed: true,
                        download_measurements: vec![],
                        upload_measurements: vec![],
                    });
                }
            }
            
            let final_progress = MeasurementProgress {
                phase: "completed".to_string(),
                ping_median_ms: ping_val.map(|v| v as f64 / 1_000_000.0),
                download_speed_mbps: dl_speed.map(|v| v / 1_000_000.0),
                upload_speed_mbps: ul_speed.map(|v| v / 1_000_000.0),
                download_measurements: stats_guard.download_measurements.clone(),
                upload_measurements: stats_guard.upload_measurements.clone(),
                progress_percent: 100.0,
                bytes_received: thread_results.iter().map(|r| r.total_bytes_received).sum(),
                bytes_sent: thread_results.iter().map(|r| r.total_bytes_sent).sum(),
                thread_count: config.thread_count,
                active_threads: states.iter().filter(|s| !s.failed).count(),
                threads: thread_infos,
                thread_results,
            };
            
            let _ = sender.send(final_progress);
        }
    }

    let state_refs: Vec<Measurement> = states
        .iter()
        //TODO whar to do on failed threads?
        .filter(|s| !s.failed)
        .cloned()
        .collect();

    let envelopes: Vec<Option<String>> = state_refs
        .iter()
        .map(|s| s.envelope.clone())
        .collect();

    if state_refs.len() != config.thread_count {
        println!("Failed threads: {}", config.thread_count - state_refs.len());
    }

    // Save results if -save option is enabled
    if config.save_results {
        let mut measurement_saver = MeasurementSaver::new(&config_clone);

        // Get all saved values
        let ping_median_value = *ping_median.lock().unwrap();
        let download_speed_value = *download_speed.lock().unwrap();
        let upload_speed_value = *upload_speed.lock().unwrap();

        if let Err(e) = measurement_saver
            .save_measurement_with_speeds(
                ping_median_value,
                download_speed_value,
                upload_speed_value,
                envelopes,
            )
            .await
        {
            eprintln!("Failed to save measurement: {}", e);
        }
    }

    Ok(state_refs)
}
