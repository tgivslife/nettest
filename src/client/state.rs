use anyhow::Result;
use log::{debug, info, trace};
use mio::{Events, Interest, Poll, Token};
use std::collections::VecDeque;
use std::time::{Instant, SystemTime};
use std::{net::SocketAddr, path::Path, time::Duration};
use std::io;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::mpsc;

use crate::client::handlers::basic_handler::{
    handle_client_readable_data, handle_client_writable_data,
};
use crate::config::constants::MIN_CHUNK_SIZE;
use crate::stream::stream::Stream;

pub const ONE_SECOND_NS: u128 = 1_000_000_000;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum TestPhase {
    GreetingSendConnectionType,
    GreetingSendToken,
    GreetingReceiveGreeting,
    GreetingReceiveResponse,
    GreetingCompleted,

    GetChunksSendChunksCommand,
    GetChunksReceiveChunk,
    GetChunksSendOk,
    GetChunksReceiveTime,
    GetChunksCompleted,

    PingSendPing,
    PingReceivePong,
    PingSendOk,
    PingReceiveTime,
    PingCompleted,

    GetTimeSendCommand,
    GetTimeReceiveChunk,
    GetTimeSendOk,
    GetTimeReceiveTime,
    GetTimeCompleted,

    PerfSendCommand,
    PerfReceiveOk,
    PerfSendChunks,
    PerfSendLastChunk,
    PerfReceiveTime,
    PerfCompleted,

    SignedResultSend,
    SignedResultReceive,
    SignedResultSendOk,
    SignedResultCompleted,
}

pub struct TestState {
    poll: Poll,
    events: Events,
    measurement_state: MeasurementState,
    thread_states: Option<Arc<Mutex<Vec<Option<crate::client::progress::ThreadState>>>>>,
    thread_id: Option<usize>,
    progress_sender: Option<Arc<Mutex<Option<mpsc::Sender<crate::client::progress::MeasurementProgress>>>>>,
    last_progress_send: Option<SystemTime>,
}

#[derive(Debug)]
pub struct MeasurementState {
    pub token: Token,
    pub phase: TestPhase,
    pub upload_bytes: Option<u64>,
    pub upload_time: Option<u64>,
    pub upload_speed: Option<f64>,
    pub download_time: Option<u64>,
    pub chunk_size: usize,
    pub ping_median: Option<u64>,
    pub phase_start_time: Option<Instant>,
    pub read_buffer: [u8; 1024 * 8],
    pub write_buffer: [u8; 1024 * 8],
    pub read_pos: usize,
    pub write_pos: usize,
    pub download_measurements: VecDeque<(u64, u64)>, // Stores (t_k^(j), b_k^(j)) for each chunk
    pub upload_measurements: VecDeque<(u64, u64)>, // Stores (t_k^(j), b_k^(j)) for each chunk
    pub failed: bool,
    pub stream: Stream,
    pub total_chunks: u32,
    pub chunk_buffer: Vec<u8>,
    pub cursor: usize,
    pub ping_times: Vec<u64>, // Store all ping times for median calculation
    pub time_result: Option<u64>,
    pub bytes_received: u64,
    pub bytes_sent: u64,
    pub time_result_buffer: Vec<u8>,
    pub envelope: Option<String>,
}

impl TestState {
    pub fn new(
        addr: SocketAddr,
        use_tls: bool,
        use_websocket: bool,
        tok: usize,
        cert_path: Option<&Path>,
        key_path: Option<&Path>,
    ) -> Result<Self> {
        Self::new_with_thread_tracking(addr, use_tls, use_websocket, tok, cert_path, key_path, None, None, None)
    }
    
    pub fn new_with_thread_tracking(
        addr: SocketAddr,
        use_tls: bool,
        use_websocket: bool,
        tok: usize,
        cert_path: Option<&Path>,
        key_path: Option<&Path>,
        thread_states: Option<Arc<Mutex<Vec<Option<crate::client::progress::ThreadState>>>>>,
        thread_id: Option<usize>,
        progress_sender: Option<Arc<Mutex<Option<mpsc::Sender<crate::client::progress::MeasurementProgress>>>>>,
    ) -> Result<Self> {
        let mut poll = Poll::new()?;
        let events = Events::with_capacity(2048);
        let token = Token(tok);
        let mut stream = if use_tls && use_websocket {
            debug!("Creating WebSocket TLS stream");
            let stream = Stream::new_websocket_tls(addr)?;
            debug!("WebSocket TLS stream created");
            stream
        } else if use_tls {
            debug!("Creating Rustls stream {:?}", addr);
            Stream::new_rustls(addr, cert_path, key_path)?
        } else {
            if use_websocket {
                debug!("Creating WebSocket stream");
                Stream::new_websocket(addr)?
            } else {
                Stream::new_tcp(addr)?
            }
        };

        debug!("Registering stream");
        stream.register(&mut poll, token, Interest::READABLE | Interest::WRITABLE)?;
        debug!("Stream registered");

        let measurement_state = MeasurementState {
            phase: TestPhase::GreetingSendConnectionType,
            upload_bytes: None,
            upload_time: None,
            upload_speed: None,
            download_time: None,
            chunk_size: MIN_CHUNK_SIZE as usize,
            ping_median: None,
            read_buffer: [0u8; 1024 * 8],
            download_measurements: VecDeque::new(),
            upload_measurements: VecDeque::new(),
            phase_start_time: None,
            failed: false,
            token,
            write_buffer: [0u8; 1024 * 8],
            read_pos: 0,
            write_pos: 0,
            stream,
            total_chunks: 1,
            chunk_buffer: Vec::with_capacity(MIN_CHUNK_SIZE as usize),
            cursor: 0,
            ping_times: Vec::new(),
            time_result: None,
            bytes_received: 0,
            bytes_sent: 0,
            time_result_buffer: Vec::new(),
            envelope: None,
        };


        Ok(Self {
            poll,
            events,
            measurement_state,
            thread_states,
            thread_id,
            progress_sender,
            last_progress_send: None,
        })
    }
    
    /// Update thread state in shared storage (called after each phase cycle)
    /// Also sends progress update once per second if progress_sender is available
    fn update_thread_state(&mut self) {
        if let (Some(ref thread_states_arc), Some(thread_id)) = (&self.thread_states, self.thread_id) {
            if let Ok(mut states) = thread_states_arc.lock() {
                let ms = &self.measurement_state;
                states[thread_id] = Some(crate::client::progress::ThreadState {
                    phase: ms.phase.clone(),
                    bytes_received: ms.bytes_received,
                    bytes_sent: ms.bytes_sent,
                    download_measurements: ms.download_measurements.iter().cloned().collect(),
                    upload_measurements: ms.upload_measurements.iter().cloned().collect(),
                    failed: ms.failed,
                });
            }
        }
        
        // Send progress update once per second
        let now = SystemTime::now();
        let should_send = if let Some(last_send) = self.last_progress_send {
            now.duration_since(last_send).map(|d| d.as_secs() >= 1).unwrap_or(false)
        } else {
            true // First time, send immediately
        };
        
        if should_send {
            if let Some(ref sender_arc) = self.progress_sender {
                if let Ok(sender_guard) = sender_arc.lock() {
                    if let Some(ref sender) = *sender_guard {
                        if let Some(ref thread_states_arc) = self.thread_states {
                            if let Ok(thread_states_guard) = thread_states_arc.lock() {
                                let ms = &self.measurement_state;
                                let phase_str = crate::client::progress::MeasurementProgress::from_phase(&ms.phase);
                                
                                // Collect thread info from all threads
                                let mut thread_infos = Vec::new();
                                let mut total_bytes_received = 0u64;
                                let mut total_bytes_sent = 0u64;
                                let mut active_count = 0;
                                
                                for (tid, state_opt) in thread_states_guard.iter().enumerate() {
                                    if let Some(ref state) = state_opt {
                                        if !state.failed {
                                            active_count += 1;
                                            total_bytes_received += state.bytes_received;
                                            total_bytes_sent += state.bytes_sent;
                                        }
                                        thread_infos.push(crate::client::progress::ThreadInfo {
                                            thread_id: tid,
                                            phase: crate::client::progress::MeasurementProgress::from_phase(&state.phase),
                                            bytes_received: state.bytes_received,
                                            bytes_sent: state.bytes_sent,
                                            failed: state.failed,
                                            download_measurements: state.download_measurements.clone(),
                                            upload_measurements: state.upload_measurements.clone(),
                                        });
                                    } else {
                                        thread_infos.push(crate::client::progress::ThreadInfo {
                                            thread_id: tid,
                                            phase: "waiting".to_string(),
                                            bytes_received: 0,
                                            bytes_sent: 0,
                                            failed: false,
                                            download_measurements: vec![],
                                            upload_measurements: vec![],
                                        });
                                    }
                                }
                                
                                let progress = crate::client::progress::MeasurementProgress {
                                    phase: phase_str,
                                    ping_median_ms: None, // Will be updated by main thread
                                    download_speed_mbps: None,
                                    upload_speed_mbps: None,
                                    download_measurements: vec![],
                                    upload_measurements: vec![],
                                    progress_percent: 0.0, // Will be calculated by main thread
                                    bytes_received: total_bytes_received,
                                    bytes_sent: total_bytes_sent,
                                    thread_count: thread_infos.len(),
                                    active_threads: active_count,
                                    threads: thread_infos,
                                    thread_results: vec![],
                                };
                                
                                if sender.send(progress).is_ok() {
                                    self.last_progress_send = Some(now);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    pub fn process_greeting(&mut self) -> Result<&mut TestState> {
        self.measurement_state.stream.reregister(
            &mut self.poll,
            self.measurement_state.token,
            Interest::WRITABLE | Interest::READABLE,
        )?;

        debug!("Greeting process_greeting");
        self.process_phase(TestPhase::GreetingCompleted, ONE_SECOND_NS * 50)?;

        debug!("Greeting completed");

        Ok(self)
    }

    pub fn run_signed_result(&mut self) -> Result<()> {
        self.measurement_state.phase = TestPhase::SignedResultSend;
        self.measurement_state.stream.reregister(
            &mut self.poll,
            self.measurement_state.token,
            Interest::WRITABLE,
        )?;
        self.process_phase(TestPhase::SignedResultCompleted, ONE_SECOND_NS * 12)?;
        Ok(())
    }

    pub fn run_perf_test(&mut self) -> Result<()> {
        self.measurement_state.phase = TestPhase::PerfSendCommand;
        self.measurement_state.stream.reregister(
            &mut self.poll,
            self.measurement_state.token,
            Interest::WRITABLE,
        )?;
        self.process_phase(TestPhase::PerfCompleted, ONE_SECOND_NS * 12)?;
        Ok(())
    }

    pub fn run_ping(&mut self) -> Result<()> {
        self.measurement_state.phase = TestPhase::PingSendPing;
        self.measurement_state.stream.reregister(
            &mut self.poll,
            self.measurement_state.token,
            Interest::WRITABLE,
        )?;
        self.process_phase(TestPhase::PingCompleted, ONE_SECOND_NS * 3)?;
        Ok(())
    }

    pub fn run_get_chunks(&mut self) -> Result<()> {
        debug!("Run get chunks");
        self.measurement_state.phase = TestPhase::GetChunksSendChunksCommand;
        self.measurement_state.stream.reregister(
            &mut self.poll,
            self.measurement_state.token,
            Interest::WRITABLE,
        )?;
        self.process_phase(TestPhase::GetChunksCompleted, ONE_SECOND_NS * 3)?;
        debug!("Run get chunks completed");
        Ok(())
    }

    pub fn run_get_time(&mut self) -> Result<()> {
        self.measurement_state.phase = TestPhase::GetTimeSendCommand;
        self.measurement_state.stream.reregister(
            &mut self.poll,
            self.measurement_state.token,
            Interest::WRITABLE,
        )?;
        self.process_phase(TestPhase::GetTimeCompleted, ONE_SECOND_NS * 12)?;
        Ok(())
    }

    fn process_phase(
        &mut self,
        phase: TestPhase,
        test_duration_ns: u128,
    ) -> Result<()> {
        if self.measurement_state.failed {
            return Ok(());
        }

        self.measurement_state.phase_start_time = Some(Instant::now());

        while self.measurement_state.phase != phase {
            self.poll
                .poll(&mut self.events, Some(Duration::from_nanos(test_duration_ns as u64)))?;

            if self.events.is_empty() {
                let time = self
                    .measurement_state
                    .phase_start_time
                    .unwrap()
                    .elapsed()
                    .as_nanos();
                let now = Instant::now().elapsed().as_nanos();
                if now - time > test_duration_ns {
                    info!(
                        "Test duration exceeded {:?} for token {:?}",
                        self.measurement_state.phase, self.measurement_state.token
                    );
                    self.measurement_state.failed = true;
                    break;
                }
            }

            for event in self.events.iter() {

            // Process events in the current poll iteration
            let mut should_remove: Result<usize, io::Error> = Ok(0);

            if event.is_readable() {
                should_remove = handle_client_readable_data(&mut self.measurement_state, &self.poll);
            } else if event.is_writable() {
                should_remove = handle_client_writable_data(&mut self.measurement_state, &self.poll);
            }

                match should_remove {
                    Ok(n) => {
                        if n == 0 {
                            trace!("No data to read");
                            self.measurement_state.failed = true;
                        }
                        // If n > 0, continue processing
                    }
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                        trace!("WouldBlock");
                        continue;
                    }
                    Err(e) => {
                        trace!("Error: {:?}", e);
                        self.measurement_state.failed = true;
                        break;
                    }
                }
            }
            
            // Update thread state after each event cycle (and send progress once per second)
            self.update_thread_state();
        }
        
        // Update thread state one final time after phase completion
        self.update_thread_state();

        Ok(())
    }

    pub fn measurement_state(&self) -> &MeasurementState {
        &self.measurement_state
    }

}
