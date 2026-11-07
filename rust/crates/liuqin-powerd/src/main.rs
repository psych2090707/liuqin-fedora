//! Unified power-key, lid and resume daemon for the Xiaomi Pad 6 Pro.
//!
//! The daemon is intentionally small at the I/O edges: evdev for the PMIC
//! power key, UPower/logind for lid and sleep, Mutter for PowerSaveMode, and
//! sysfs for the physical panel state.  All policy decisions live in
//! `liuqin-power-core`.

use anyhow::{Context, Result};
use futures_util::StreamExt;
use liuqin_power_core::{
    Action, Config, GnomePowerAction, KeyPress, PowerCore, SuspendCause, WakeCause,
    LID_DEBOUNCE_MS, RESUME_GRACE_MS,
};
use serde::Serialize;
use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command as StdCommand, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::process::Command;
use tokio::signal::unix::{signal, SignalKind};
use tokio::sync::mpsc;
use tracing::{debug, error, info, warn};
use zbus::OwnedVariant;
use zbus::Proxy;

const CONFIG: &str = "/etc/liuqin/power-policy.conf";
const STATE_DIR_NAME: &str = "liuqin-power-keyd";
const STATE_FILE: &str = "power-state.json";
const DRY_RUN_STATE_FILE: &str = "power-state-dryrun.json";
const MARKER_FILE: &str = "power-key-action";
const STARTUP_MARKER_MS: u64 = 30_000;
const SESSION_RECONNECT_MS: u64 = 2_000;

#[derive(Debug)]
enum Event {
    PowerDown,
    PowerUp,
    Lid(bool),
    PowerSource(bool),
    PrepareForSleep(bool),
    MutterMode(u32),
    Input,
    SuspendCallError(String),
    NvtResumeFailed,
}

#[derive(Clone, Copy, Debug)]
struct HeldPress {
    at_ms: u64,
    screen_lit: bool,
    gnome_action: GnomePowerAction,
    long_fired: bool,
}

#[derive(Clone, Debug, Default)]
struct DisplayReading {
    lit: bool,
    bl_power: Option<u32>,
    dpms: Option<String>,
    enabled: Option<String>,
    mode: Option<u32>,
    backlight: Option<PathBuf>,
    dsi: Vec<PathBuf>,
}

#[derive(Serialize)]
struct StateSnapshot {
    state: &'static str,
    lid_closed: bool,
    on_battery: bool,
    sleeping: bool,
    suspend_pending: bool,
    screen_lit: bool,
    last_resume_monotonic_ms: u64,
    wake_cause: &'static str,
    retry_count: u32,
    blocked_reason: Option<String>,
    resuspend_at_monotonic_ms: Option<u64>,
    updated_monotonic_ms: u64,
}

struct Runtime {
    core: PowerCore,
    session: Session,
    system: zbus::Connection,
    state_path: PathBuf,
    marker_path: PathBuf,
    dry_run: bool,
    last_state_json: Option<String>,
    last_config_text: String,
    last_config_check_ms: u64,
    last_session_attempt_ms: u64,
    last_recovery_ms: Option<u64>,
    last_display_check_ms: u64,
    last_state_dir_attempt_ms: u64,
    pending_lid: Option<(bool, u64)>,
    held: Option<HeldPress>,
    rtc_alarm_set: bool,
    nvt_failed: Arc<AtomicBool>,
}

struct Session {
    conn: Option<zbus::Connection>,
    runtime: PathBuf,
    home: PathBuf,
    user: String,
}

impl Session {
    fn new(runtime: PathBuf, home: PathBuf, user: String) -> Self {
        Self {
            conn: None,
            runtime,
            home,
            user,
        }
    }

    async fn ensure(&mut self) -> bool {
        if let Some(conn) = self.conn.as_ref() {
            if !conn.is_closed() {
                return true;
            }
            self.conn = None;
        }
        let socket = self.runtime.join("bus");
        if !socket.exists() {
            return false;
        }
        let address = format!("unix:path={}", socket.display());
        match zbus::connection::Builder::address(address.as_str())
            .build()
            .await
        {
            Ok(conn) => {
                info!("connected to the user session bus");
                self.conn = Some(conn);
                true
            }
            Err(error) => {
                debug!("cannot connect to the user session bus: {error}");
                false
            }
        }
    }

    fn conn(&self) -> Option<&zbus::Connection> {
        self.conn.as_ref()
    }

    async fn mode(&self) -> Option<u32> {
        let conn = self.conn()?;
        let proxy = tokio::time::timeout(
            Duration::from_secs(2),
            Proxy::new(
                conn,
                "org.gnome.Mutter.DisplayConfig",
                "/org/gnome/Mutter/DisplayConfig",
                "org.gnome.Mutter.DisplayConfig",
            ),
        )
        .await
        .ok()?
        .ok()?;
        if let Ok(Ok(mode)) = tokio::time::timeout(
            Duration::from_secs(2),
            proxy.get_property::<i32>("PowerSaveMode"),
        )
        .await
        {
            return Some(mode.max(0) as u32);
        }
        tokio::time::timeout(
            Duration::from_secs(2),
            proxy.get_property::<u32>("PowerSaveMode"),
        )
        .await
        .ok()?
        .ok()
    }

    async fn set_mode(&self, mode: u32) -> Result<()> {
        let conn = self.conn().context("no user session bus")?;
        let proxy = tokio::time::timeout(
            Duration::from_secs(2),
            Proxy::new(
                conn,
                "org.gnome.Mutter.DisplayConfig",
                "/org/gnome/Mutter/DisplayConfig",
                "org.gnome.Mutter.DisplayConfig",
            ),
        )
        .await
        .map_err(|_| anyhow::anyhow!("Mutter proxy timed out"))??;
        // Mutter exposes PowerSaveMode as a signed 32-bit integer (`i`) on
        // Fedora 45, even though the conceptual range is 0..3.
        tokio::time::timeout(
            Duration::from_secs(2),
            proxy.set_property("PowerSaveMode", mode as i32),
        )
        .await
        .map_err(|_| anyhow::anyhow!("Mutter set_property timed out"))??;
        Ok(())
    }

    async fn screensaver_active(&self) -> bool {
        let Some(conn) = self.conn() else {
            return false;
        };
        let Ok(Ok(proxy)) = tokio::time::timeout(
            Duration::from_millis(500),
            Proxy::new(
                conn,
                "org.gnome.ScreenSaver",
                "/org/gnome/ScreenSaver",
                "org.gnome.ScreenSaver",
            ),
        )
        .await
        else {
            return false;
        };
        tokio::time::timeout(
            Duration::from_millis(300),
            proxy.call::<_, _, bool>("GetActive", &()),
        )
        .await
        .ok()
        .and_then(|result| result.ok())
        .unwrap_or(false)
    }

    async fn lock(&self) -> bool {
        let Some(conn) = self.conn() else {
            warn!("no user session; skipping lock before suspend");
            return false;
        };
        // Ask logind first: this path stays responsive even when GNOME Shell
        // is slow to answer the direct ScreenSaver call.  It is fire-and-forget
        // with a short bound; suspend must not wait for a 25 s zbus timeout.
        let _ = tokio::time::timeout(
            Duration::from_millis(500),
            Command::new("/usr/bin/loginctl")
                .arg("lock-session")
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .kill_on_drop(true)
                .status(),
        )
        .await;
        if let Ok(Ok(proxy)) = tokio::time::timeout(
            Duration::from_millis(500),
            Proxy::new(
                conn,
                "org.gnome.ScreenSaver",
                "/org/gnome/ScreenSaver",
                "org.gnome.ScreenSaver",
            ),
        )
        .await
        {
            let _ = tokio::time::timeout(
                Duration::from_millis(300),
                proxy.call::<_, _, ()>("Lock", &()),
            )
            .await;
        }
        // One short confirmation is enough; the shield can finish activating
        // while logind is already entering sleep.
        if tokio::time::timeout(Duration::from_millis(300), self.screensaver_active()).await
            == Ok(true)
        {
            info!("session lock active; suspending");
            true
        } else {
            warn!("session lock not confirmed; suspending anyway");
            false
        }
    }

    async fn gnome_power_action(&self) -> GnomePowerAction {
        if self.conn.is_none() {
            return GnomePowerAction::Nothing;
        }
        let output = tokio::time::timeout(
            Duration::from_secs(2),
            Command::new("/usr/bin/gsettings")
                .args([
                    "get",
                    "org.gnome.settings-daemon.plugins.power",
                    "power-button-action",
                ])
                .env("HOME", &self.home)
                .env("USER", &self.user)
                .env("LOGNAME", &self.user)
                .env("XDG_RUNTIME_DIR", &self.runtime)
                .env(
                    "DBUS_SESSION_BUS_ADDRESS",
                    format!("unix:path={}", self.runtime.join("bus").display()),
                )
                .output(),
        )
        .await;
        match output {
            Ok(Ok(output)) if output.status.success() => {
                GnomePowerAction::from_gsettings(&String::from_utf8_lossy(&output.stdout))
            }
            Ok(Ok(_)) | Ok(Err(_)) | Err(_) => {
                // A session exists but the setting is unreadable.  Let GNOME
                // own the key rather than risking a double action.
                GnomePowerAction::Other
            }
        }
    }

    async fn gnome_inhibited(&self) -> Option<bool> {
        let conn = self.conn()?;
        let proxy = tokio::time::timeout(
            Duration::from_secs(1),
            Proxy::new(
                conn,
                "org.gnome.SessionManager",
                "/org/gnome/SessionManager",
                "org.gnome.SessionManager",
            ),
        )
        .await
        .ok()?
        .ok()?;
        tokio::time::timeout(
            Duration::from_secs(1),
            proxy.call::<_, _, bool>("IsInhibited", &(4u32,)),
        )
        .await
        .ok()?
        .ok()
    }
}

fn now_ms() -> u64 {
    let mut timespec = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // CLOCK_BOOTTIME keeps advancing across suspend, unlike CLOCK_MONOTONIC.
    let result = unsafe { libc::clock_gettime(libc::CLOCK_BOOTTIME, &mut timespec) };
    if result != 0 {
        return 0;
    }
    timespec.tv_sec as u64 * 1_000 + timespec.tv_nsec as u64 / 1_000_000
}

fn read_u32(path: &Path) -> Option<u32> {
    fs::read_to_string(path)
        .ok()
        .and_then(|value| value.trim().parse().ok())
}

fn read_string(path: &Path) -> Option<String> {
    fs::read_to_string(path)
        .ok()
        .map(|value| value.trim().to_string())
}

fn write_private(path: &Path, text: &str) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut options = fs::OpenOptions::new();
    options.write(true).create(true).truncate(true).mode(0o600);
    let mut file = options.open(path)?;
    file.write_all(text.as_bytes())?;
    file.sync_all()?;
    Ok(())
}

fn read_display(mode: Option<u32>) -> DisplayReading {
    let mut reading = DisplayReading {
        mode,
        ..DisplayReading::default()
    };

    if let Ok(entries) = fs::read_dir("/sys/class/backlight") {
        for entry in entries.flatten() {
            let path = entry.path();
            if let Some(value) = read_u32(&path.join("bl_power")) {
                reading.bl_power = Some(value);
                reading.backlight = Some(path);
                break;
            }
        }
    }

    if let Ok(entries) = fs::read_dir("/sys/class/drm") {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if !name.contains("-DSI-") {
                continue;
            }
            let path = entry.path();
            let dpms = read_string(&path.join("dpms"));
            let enabled = read_string(&path.join("enabled"));
            if reading.dpms.is_none() {
                reading.dpms = dpms.clone();
                reading.enabled = enabled.clone();
            }
            if dpms.as_deref() == Some("On") && enabled.as_deref() == Some("enabled") {
                reading.dsi = vec![path];
                break;
            }
            reading.dsi.push(path);
        }
    }

    let backlight_on = reading.bl_power.map(|value| value == 0).unwrap_or(true);
    let dsi_on = if reading.dsi.is_empty() {
        // Some kernels hide the connector from /sys/class/drm; fall back to
        // Mutter rather than declaring a working panel dark.
        reading.mode.map(|mode| mode != 3).unwrap_or(true)
    } else {
        reading.dsi.iter().any(|path| {
            read_string(&path.join("dpms")).as_deref() == Some("On")
                && read_string(&path.join("enabled")).as_deref() == Some("enabled")
        })
    };
    let mode_on = reading.mode.map(|mode| mode != 3).unwrap_or(true);
    reading.lit = backlight_on && dsi_on && mode_on;
    reading
}

fn log_display(reading: &DisplayReading, prefix: &str) {
    info!(
        "{prefix}: lit={} bl_power={:?} dpms={:?} enabled={:?} mode={:?}",
        reading.lit, reading.bl_power, reading.dpms, reading.enabled, reading.mode
    );
}

async fn ensure_on(
    session: &Session,
    lid_closed: bool,
    dry_run: bool,
    last_recovery_ms: &mut Option<u64>,
    nvt_failed: &AtomicBool,
) -> bool {
    let mut reading = read_display(session.mode().await);
    if reading.lit {
        debug!("ensure-on: panel already lit");
        return true;
    }
    log_display(&reading, "ensure-on requested");
    if dry_run {
        info!("dry-run: would set PowerSaveMode=0");
        return false;
    }
    if let Err(error) = session.set_mode(0).await {
        warn!("ensure-on: cannot set PowerSaveMode=0: {error}");
        return false;
    }
    // A normal panel resume can take longer than 300 ms, and the NVT touch
    // controller can report success before failing closed a moment later.
    // Watch the kernel-side failure flag in short slices instead of blocking
    // the main loop for a blind two seconds.
    nvt_failed.store(false, Ordering::SeqCst);
    let mut nvt_failure_seen = false;
    for _ in 0..8 {
        tokio::time::sleep(Duration::from_millis(250)).await;
        if nvt_failed.swap(false, Ordering::SeqCst) {
            nvt_failure_seen = true;
            break;
        }
    }
    reading = read_display(session.mode().await);
    if reading.lit && !nvt_failure_seen {
        info!("ensure-on: panel lit after resume");
        return true;
    }
    if nvt_failure_seen {
        info!("ensure-on: NVT failure arrived during resume; forcing a panel cycle");
    }
    if lid_closed {
        info!("ensure-on: panel still dark with the lid closed; not cycling it");
        return false;
    }

    let now = now_ms();
    if last_recovery_ms
        .map(|at| now.saturating_sub(at) < 10_000)
        .unwrap_or(false)
    {
        warn!("ensure-on: panel still dark; skipping a second forced cycle");
        return false;
    }
    *last_recovery_ms = Some(now);
    info!("ensure-on: panel still dark; forcing one off/on cycle");
    if let Err(error) = session.set_mode(3).await {
        warn!("ensure-on: cannot set PowerSaveMode=3 for recovery: {error}");
        return false;
    }
    tokio::time::sleep(Duration::from_millis(300)).await;
    if let Err(error) = session.set_mode(0).await {
        warn!("ensure-on: cannot set PowerSaveMode=0 after recovery: {error}");
        return false;
    }
    tokio::time::sleep(Duration::from_millis(800)).await;
    reading = read_display(session.mode().await);
    log_display(&reading, "ensure-on result");
    reading.lit
}

async fn ensure_off(session: &Session, dry_run: bool) -> bool {
    if dry_run {
        info!("dry-run: would set PowerSaveMode=3");
        return false;
    }
    match session.set_mode(3).await {
        Ok(()) => {
            info!("ensure-off: PowerSaveMode=3");
            true
        }
        Err(error) => {
            warn!("ensure-off failed: {error}");
            false
        }
    }
}

async fn lid_is_closed(system: &zbus::Connection) -> Option<bool> {
    let proxy = Proxy::new(
        system,
        "org.freedesktop.UPower",
        "/org/freedesktop/UPower",
        "org.freedesktop.UPower",
    )
    .await
    .ok()?;
    proxy.get_property("LidIsClosed").await.ok()
}

async fn sleep_inhibitor(system: &zbus::Connection, session: &Session) -> Option<String> {
    if let Ok(Ok(proxy)) = tokio::time::timeout(
        Duration::from_secs(2),
        Proxy::new(
            system,
            "org.freedesktop.login1",
            "/org/freedesktop/login1",
            "org.freedesktop.login1.Manager",
        ),
    )
    .await
    {
        match tokio::time::timeout(
            Duration::from_secs(2),
            proxy.call::<_, _, Vec<(String, String, String, String, u32, u32)>>(
                "ListInhibitors",
                &(),
            ),
        )
        .await
        {
            Ok(Ok(inhibitors)) => {
                for (what, who, why, mode, _uid, _pid) in inhibitors {
                    if what.split(':').any(|item| item == "sleep") && mode == "block" {
                        return Some(format!("logind inhibitor: {who}: {why}"));
                    }
                }
            }
            Ok(Err(error)) => {
                // Do not turn an unreadable inhibitor list into an automatic
                // suspend; the next user action still has a normal path.
                return Some(format!("cannot list logind inhibitors: {error}"));
            }
            Err(_) => {
                return Some("cannot list logind inhibitors: timed out".to_string());
            }
        }
    }
    match session.gnome_inhibited().await {
        Some(true) => Some("GNOME session inhibitor (logout/suspend)".to_string()),
        None if session.conn().is_some() => {
            Some("cannot query GNOME session inhibitors".to_string())
        }
        _ => None,
    }
}

fn write_marker(path: &Path, now: u64) {
    let temp = path.with_extension(format!("tmp.{now}"));
    if let Err(error) = write_private(&temp, &format!("{now}\n")) {
        warn!("cannot write power-key marker: {error}");
        return;
    }
    if let Err(error) = fs::rename(&temp, path) {
        warn!("cannot replace power-key marker: {error}");
        let _ = fs::remove_file(&temp);
    }
}

fn clear_marker(path: &Path) {
    if let Err(error) = fs::remove_file(path) {
        if error.kind() != std::io::ErrorKind::NotFound {
            warn!("cannot remove power-key marker: {error}");
        }
    }
}

fn marker_recent(path: &Path) -> bool {
    fs::metadata(path)
        .and_then(|meta| meta.modified())
        .ok()
        .and_then(|modified| modified.elapsed().ok())
        .map(|age| age.as_millis() as u64 <= STARTUP_MARKER_MS)
        .unwrap_or(false)
}

fn rtc_alarm_is_set() -> bool {
    let Ok(text) = fs::read_to_string("/sys/class/rtc/rtc0/wakealarm") else {
        return false;
    };
    let text = text.trim();
    if text.is_empty() {
        return false;
    }
    match text.parse::<i64>() {
        Ok(alarm) => {
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|duration| duration.as_secs() as i64)
                .unwrap_or(0);
            alarm <= now + 5
        }
        Err(_) => true,
    }
}

fn write_state(runtime: &mut Runtime, now: u64) {
    let snapshot = StateSnapshot {
        state: runtime.core.state(now).as_str(),
        lid_closed: runtime.core.lid_closed,
        on_battery: runtime.core.on_battery,
        sleeping: runtime.core.sleeping,
        suspend_pending: runtime.core.suspend_pending,
        screen_lit: runtime.core.screen_lit,
        last_resume_monotonic_ms: runtime.core.last_resume_ms.unwrap_or(0),
        wake_cause: runtime.core.wake_cause.as_str(),
        retry_count: runtime.core.retry_count,
        blocked_reason: runtime.core.blocked_reason.clone(),
        resuspend_at_monotonic_ms: runtime.core.retry_at_ms,
        updated_monotonic_ms: now,
    };
    let Ok(text) = serde_json::to_string(&snapshot) else {
        warn!("cannot encode power state");
        return;
    };
    if runtime.last_state_json.as_deref() == Some(text.as_str()) {
        return;
    }
    let temp = runtime.state_path.with_extension("tmp");
    if let Err(error) = write_private(&temp, &format!("{text}\n")) {
        warn!("cannot write power state: {error}");
        return;
    }
    if let Err(error) = fs::rename(&temp, &runtime.state_path) {
        warn!("cannot replace power state: {error}");
        let _ = fs::remove_file(&temp);
        return;
    }
    runtime.last_state_json = Some(text);
}

fn state_dir_for_uid(uid: &str) -> PathBuf {
    PathBuf::from(format!("/run/user/{uid}")).join(STATE_DIR_NAME)
}

fn parse_args() -> (bool, bool, bool, bool) {
    let mut dry_run = false;
    let mut probe = false;
    let mut ensure_on = false;
    let mut ensure_off = false;
    for arg in std::env::args().skip(1) {
        match arg.as_str() {
            "--dry-run" => dry_run = true,
            "--probe" => probe = true,
            "--ensure-on" => ensure_on = true,
            "--ensure-off" => ensure_off = true,
            _ => {}
        }
    }
    (dry_run, probe, ensure_on, ensure_off)
}

async fn probe_once(session: &mut Session, system: &zbus::Connection) -> Result<()> {
    let upower = Proxy::new(
        system,
        "org.freedesktop.UPower",
        "/org/freedesktop/UPower",
        "org.freedesktop.UPower",
    )
    .await?;
    let lid: bool = upower.get_property("LidIsClosed").await.unwrap_or(false);
    let battery: bool = upower.get_property("OnBattery").await.unwrap_or(false);
    session.ensure().await;
    let mode = session.mode().await;
    let reading = read_display(mode);
    println!(
        "{}",
        serde_json::json!({
            "lid_closed": lid,
            "on_battery": battery,
            "session_bus": session.conn().is_some(),
            "power_save_mode": mode,
            "screen_lit": reading.lit,
            "bl_power": reading.bl_power,
            "dpms": reading.dpms,
            "enabled": reading.enabled,
            "gnome_power_action": format!("{:?}", session.gnome_power_action().await),
        })
    );
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .with_target(false)
        .init();

    let (dry_run, probe, ensure_on_requested, ensure_off_requested) = parse_args();
    let uid = std::env::var("LIUQIN_UID").unwrap_or_else(|_| "1000".to_string());
    let home = std::env::var("HOME").unwrap_or_else(|_| "/home/laplus".to_string());
    let user = std::env::var("USER").unwrap_or_else(|_| "laplus".to_string());
    let runtime_dir = PathBuf::from(format!("/run/user/{uid}"));
    let state_dir = state_dir_for_uid(&uid);
    if let Err(error) = fs::create_dir_all(&state_dir) {
        warn!("cannot create {}: {error}", state_dir.display());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&state_dir, fs::Permissions::from_mode(0o700));
    }
    let state_path = state_dir.join(if dry_run {
        DRY_RUN_STATE_FILE
    } else {
        STATE_FILE
    });
    let marker_path = state_dir.join(MARKER_FILE);

    let system = zbus::Connection::system()
        .await
        .context("cannot connect to the system bus")?;
    let mut session = Session::new(runtime_dir, PathBuf::from(home), user);

    if probe {
        return probe_once(&mut session, &system).await;
    }

    if ensure_on_requested || ensure_off_requested {
        session.ensure().await;
        let lid_closed = lid_is_closed(&system).await.unwrap_or(false);
        if ensure_on_requested {
            let mut last_recovery = None;
            let nvt_failed = AtomicBool::new(false);
            let lit = ensure_on(&session, lid_closed, false, &mut last_recovery, &nvt_failed).await;
            println!("{}", serde_json::json!({ "ensure_on_lit": lit }));
        } else {
            let ok = ensure_off(&session, false).await;
            println!("{}", serde_json::json!({ "ensure_off": ok }));
        }
        return Ok(());
    }

    let upower = Proxy::new(
        &system,
        "org.freedesktop.UPower",
        "/org/freedesktop/UPower",
        "org.freedesktop.UPower",
    )
    .await
    .context("cannot create the UPower proxy")?;
    let lid: bool = upower.get_property("LidIsClosed").await.unwrap_or(false);
    let on_battery: bool = upower.get_property("OnBattery").await.unwrap_or(false);
    session.ensure().await;
    let mode = session.mode().await;
    let reading = read_display(mode);
    log_display(&reading, "startup display");
    info!(
        "startup: lid_closed={} on_battery={} session={} dry_run={}",
        lid,
        on_battery,
        session.conn().is_some(),
        dry_run
    );

    let config_text = fs::read_to_string(CONFIG).unwrap_or_default();
    let mut core = PowerCore::new(Config::parse(&config_text), now_ms());
    if marker_recent(&marker_path) {
        info!("recent power-key marker present; startup suspend suppressed");
        core.user_override = true;
        core.skip_startup_suspend();
    }
    let startup_actions = core.initial(lid, on_battery, reading.lit, now_ms());
    if core.user_override {
        core.skip_startup_suspend();
    }
    let nvt_failed = Arc::new(AtomicBool::new(false));

    let mut runtime = Runtime {
        core,
        session,
        system: system.clone(),
        state_path,
        marker_path,
        dry_run,
        last_state_json: None,
        last_config_text: config_text,
        last_config_check_ms: 0,
        last_session_attempt_ms: 0,
        last_recovery_ms: None,
        last_display_check_ms: 0,
        last_state_dir_attempt_ms: 0,
        pending_lid: None,
        held: None,
        rtc_alarm_set: false,
        nvt_failed: nvt_failed.clone(),
    };

    let (tx, mut rx) = mpsc::channel::<Event>(128);
    spawn_upower_watch(system.clone(), tx.clone());
    spawn_logind_watch(system.clone(), tx.clone());
    spawn_mutter_watch(runtime.session.runtime.clone(), tx.clone());
    spawn_power_key_watch(tx.clone());
    spawn_input_watch(tx.clone());
    spawn_kernel_watch(tx.clone(), nvt_failed.clone());

    let mut actions = startup_actions;
    if !actions.is_empty() && runtime.dry_run {
        info!("dry-run: startup actions {actions:?}");
        actions.clear();
    }
    run_actions(&mut runtime, actions, &tx).await;
    write_state(&mut runtime, now_ms());

    let mut ticker = tokio::time::interval(Duration::from_millis(100));
    let mut sigterm = signal(SignalKind::terminate()).context("cannot install SIGTERM handler")?;
    let mut sigint = signal(SignalKind::interrupt()).context("cannot install SIGINT handler")?;

    loop {
        tokio::select! {
            _ = sigterm.recv() => {
                info!("SIGTERM received; stopping");
                break;
            }
            _ = sigint.recv() => {
                info!("SIGINT received; stopping");
                break;
            }
            _ = ticker.tick() => {
                let now = now_ms();
                let mut actions = Vec::new();

                if let Some((closed, at)) = runtime.pending_lid {
                    if now.saturating_sub(at) >= LID_DEBOUNCE_MS {
                        runtime.pending_lid = None;
                        clear_marker(&runtime.marker_path);
                        info!("lid {}", if closed { "closed" } else { "opened" });
                        actions.extend(runtime.core.lid_changed(closed, now));
                        if !closed {
                            runtime.session.ensure().await;
                        }
                    }
                }

                if let Some(mut held) = runtime.held {
                    if !held.long_fired && now.saturating_sub(held.at_ms) >= 1_500 {
                        held.long_fired = true;
                        runtime.held = Some(held);
                        info!("power key long press");
                        if !runtime.dry_run {
                            write_marker(&runtime.marker_path, now);
                        }
                        actions.extend(runtime.core.power_key(
                            KeyPress::Long,
                            held.screen_lit,
                            held.gnome_action,
                            now,
                        ));
                    }
                }

                actions.extend(runtime.core.timer(now));
                if !actions.is_empty() {
                    run_actions(&mut runtime, actions, &tx).await;
                }

                if now.saturating_sub(runtime.last_config_check_ms) >= 1_000 {
                    runtime.last_config_check_ms = now;
                    if let Ok(text) = fs::read_to_string(CONFIG) {
                        if text != runtime.last_config_text {
                            runtime.last_config_text = text.clone();
                            let config = Config::parse(&text);
                            info!("power policy reloaded: {config:?}");
                            runtime.core.set_config(config);
                        }
                    }
                }

                if runtime.session.conn().is_none()
                    && now.saturating_sub(runtime.last_session_attempt_ms) >= SESSION_RECONNECT_MS
                {
                    runtime.last_session_attempt_ms = now;
                    runtime.session.ensure().await;
                }

                // Keep the physical screen fact fresh.  Mutter's mode alone is
                // not trusted: a failed NVT resume can leave mode 0 while the
                // panel and DSI connector are still off.  Twice a second is
                // enough; the 100 ms tick exists for the long-press timer.
                if now.saturating_sub(runtime.last_display_check_ms) >= 500 {
                    runtime.last_display_check_ms = now;
                    let mode = runtime.session.mode().await;
                    let reading = read_display(mode);
                    runtime.core.set_screen_lit(reading.lit);
                    if let Some(mode) = mode {
                        runtime.core.display_changed(mode, now);
                    }
                }
                // /run/user/1000 appears only after the user manager starts.
                // Service startup can precede it, so retry the state directory.
                if !runtime.state_path.parent().map(Path::exists).unwrap_or(false)
                    && now.saturating_sub(runtime.last_state_dir_attempt_ms) >= 2_000
                {
                    runtime.last_state_dir_attempt_ms = now;
                    if let Some(parent) = runtime.state_path.parent() {
                        let _ = fs::create_dir_all(parent);
                    }
                }
                write_state(&mut runtime, now);
            }
            Some(event) = rx.recv() => {
                let now = now_ms();
                let mut actions = Vec::new();
                match event {
                    Event::PowerDown => {
                        if runtime.held.is_some() {
                            debug!("power key down while already held; ignored");
                            continue;
                        }
                        let reading = read_display(runtime.session.mode().await);
                        let gnome_action = runtime.session.gnome_power_action().await;
                        runtime.held = Some(HeldPress {
                            at_ms: now,
                            screen_lit: reading.lit,
                            gnome_action,
                            long_fired: false,
                        });
                        info!(
                            "power key down: screen_lit={} lid_closed={} gnome={:?}",
                            reading.lit, runtime.core.lid_closed, gnome_action
                        );
                    }
                    Event::PowerUp => {
                        let Some(held) = runtime.held.take() else {
                            continue;
                        };
                        let held_ms = now.saturating_sub(held.at_ms);
                        if held.long_fired {
                            debug!("power key released after long action");
                            continue;
                        }
                        if held_ms < 40 {
                            debug!("power key debounce ({held_ms} ms)");
                            continue;
                        }
                        info!("power key short press ({held_ms} ms)");
                        if !runtime.dry_run {
                            write_marker(&runtime.marker_path, now);
                        }
                        actions.extend(runtime.core.power_key(
                            KeyPress::Short,
                            held.screen_lit,
                            held.gnome_action,
                            now,
                        ));
                    }
                    Event::Lid(closed) => {
                        if runtime.pending_lid.map(|(value, _)| value) != Some(closed) {
                            runtime.pending_lid = Some((closed, now));
                        }
                    }
                    Event::PowerSource(on_battery) => {
                        info!("power source {}", if on_battery { "battery" } else { "AC" });
                        runtime.core.power_source(on_battery);
                    }
                    Event::PrepareForSleep(entering) => {
                        if entering {
                            runtime.rtc_alarm_set = rtc_alarm_is_set();
                            runtime.held = None;
                            clear_marker(&runtime.marker_path);
                            info!(
                                "entering sleep (rtc_alarm={})",
                                runtime.rtc_alarm_set
                            );
                            runtime.core.prepare_sleep(true, now);
                        } else {
                            let scheduled = runtime.rtc_alarm_set;
                            runtime.rtc_alarm_set = false;
                            let marker_exists = runtime.marker_path.exists();
                            let recent_input = runtime
                                .core
                                .last_input_ms
                                .map(|at| now.saturating_sub(at) <= RESUME_GRACE_MS)
                                .unwrap_or(false);
                            let recent_lid_open = !runtime.core.lid_closed
                                && runtime
                                    .core
                                    .last_lid_change_ms
                                    .map(|at| now.saturating_sub(at) <= RESUME_GRACE_MS)
                                    .unwrap_or(false);
                            let user_wake = recent_input
                                || marker_exists
                                || recent_lid_open
                                || runtime.held.is_some();
                            runtime.core.wake_cause = if scheduled {
                                WakeCause::Scheduled
                            } else if user_wake {
                                WakeCause::User
                            } else {
                                WakeCause::Abnormal
                            };
                            info!(
                                "resumed: cause={} slept_ms={} lid_closed={}",
                                runtime.core.wake_cause.as_str(),
                                runtime
                                    .core
                                    .sleep_started_ms
                                    .map(|at| now.saturating_sub(at))
                                    .unwrap_or(0),
                                runtime.core.lid_closed
                            );
                            actions.extend(runtime.core.prepare_sleep(false, now));
                            if scheduled {
                                runtime.core.cancel_retry("scheduled RTC wake");
                            } else if user_wake {
                                runtime.core.user_input(now);
                            } else if !runtime.core.lid_closed
                                && runtime.core.note_abnormal_short_wake(now)
                            {
                                info!("abnormal short wake with the lid open; one retry armed");
                            }
                            runtime.session.ensure().await;
                            clear_marker(&runtime.marker_path);
                        }
                    }
                    Event::MutterMode(mode) => {
                        runtime.core.display_changed(mode, now);
                        let reading = read_display(Some(mode));
                        runtime.core.set_screen_lit(reading.lit);
                        if reading.lit {
                            info!("display on (PowerSaveMode={mode})");
                        } else {
                            info!("display dark (PowerSaveMode={mode})");
                        }
                    }
                    Event::Input => {
                        runtime.core.user_input(now);
                    }
                    Event::SuspendCallError(error) => {
                        if !runtime.core.sleeping {
                            warn!("suspend request failed: {error}");
                            actions.extend(runtime.core.suspend_failed(now));
                        }
                    }
                    Event::NvtResumeFailed => {
                        if runtime.core.sleeping
                            || runtime.core.lid_closed
                            || runtime.core.power_save_mode == Some(3)
                        {
                            debug!("NVT resume failure ignored: screen is intentionally off");
                            runtime.nvt_failed.store(false, Ordering::SeqCst);
                        } else if runtime
                            .last_recovery_ms
                            .map(|at| now.saturating_sub(at) < 10_000)
                            .unwrap_or(false)
                        {
                            warn!("NVT resume failure detected again; recovery already attempted");
                            runtime.nvt_failed.store(false, Ordering::SeqCst);
                        } else {
                            warn!("NVT resume failure detected; forcing one panel off/on cycle");
                            runtime.last_recovery_ms = Some(now);
                            if !runtime.dry_run {
                                let _ = runtime.session.set_mode(3).await;
                                tokio::time::sleep(Duration::from_millis(300)).await;
                                let _ = runtime.session.set_mode(0).await;
                                tokio::time::sleep(Duration::from_millis(1_500)).await;
                                let reading = read_display(runtime.session.mode().await);
                                runtime.core.set_screen_lit(reading.lit);
                                runtime.nvt_failed.store(false, Ordering::SeqCst);
                                if reading.lit {
                                    info!("panel recovered after NVT resume failure");
                                } else {
                                    warn!("panel still dark after NVT recovery cycle");
                                }
                            }
                        }
                    }
                }
                if !actions.is_empty() {
                    run_actions(&mut runtime, actions, &tx).await;
                }
                write_state(&mut runtime, now);
            }
        }
    }
    info!("liuqin-powerd stopped");
    // evdev readers live in blocking threads that intentionally block in
    // fetch_events(); letting the Tokio runtime drop would wait for them
    // forever.  Exit the process explicitly so systemd stop is immediate.
    std::process::exit(0);
}

// `run_actions` takes the runtime and the event sender.  The fourth argument is
// kept for the caller's convenience when a future D-Bus interface wants to
// enqueue follow-up work; it is intentionally unused today.
async fn run_actions(runtime: &mut Runtime, actions: Vec<Action>, tx: &mpsc::Sender<Event>) {
    if actions.is_empty() {
        return;
    }
    debug!("actions: {actions:?}");

    let retry_requested = actions.iter().any(|action| {
        matches!(
            action,
            Action::Suspend {
                cause: SuspendCause::Retry
            }
        )
    });
    if retry_requested {
        if let Some(reason) = sleep_inhibitor(&runtime.system, &runtime.session).await {
            warn!("automatic re-suspend blocked: {reason}");
            runtime.core.suspend_pending = false;
            runtime.core.suspend_confirm_at_ms = None;
            runtime.core.set_blocked(Some(reason));
            return;
        }
        runtime.core.set_blocked(None);
    }

    for action in actions {
        match action {
            Action::EnsureOn => {
                if runtime.core.lid_closed {
                    info!("ensure-on skipped: lid is closed");
                    continue;
                }
                ensure_on(
                    &runtime.session,
                    runtime.core.lid_closed,
                    runtime.dry_run,
                    &mut runtime.last_recovery_ms,
                    &runtime.nvt_failed,
                )
                .await;
            }
            Action::EnsureOff => {
                ensure_off(&runtime.session, runtime.dry_run).await;
            }
            Action::LockSession => {
                if !runtime.dry_run {
                    runtime.session.lock().await;
                }
            }
            Action::Suspend { cause } => {
                if matches!(cause, SuspendCause::Lid | SuspendCause::Startup)
                    && (runtime.pending_lid.map(|(closed, _)| closed) == Some(false)
                        || lid_is_closed(&runtime.system).await == Some(false))
                {
                    info!("lid already open; suspend cancelled");
                    runtime.core.suspend_pending = false;
                    runtime.core.suspend_confirm_at_ms = None;
                    continue;
                }
                if runtime.dry_run {
                    info!("dry-run: would request suspend (cause={})", cause.as_str());
                    runtime.core.suspend_pending = false;
                    runtime.core.suspend_confirm_at_ms = None;
                    continue;
                }
                info!("requesting suspend (cause={})", cause.as_str());
                let system = runtime.system.clone();
                let tx = tx.clone();
                tokio::spawn(async move {
                    let result = async {
                        let proxy = Proxy::new(
                            &system,
                            "org.freedesktop.login1",
                            "/org/freedesktop/login1",
                            "org.freedesktop.login1.Manager",
                        )
                        .await?;
                        proxy.call::<_, _, ()>("Suspend", &(false,)).await
                    }
                    .await;
                    if let Err(error) = result {
                        let _ = tx.send(Event::SuspendCallError(error.to_string())).await;
                    } else {
                        info!("logind Suspend call returned");
                    }
                });
            }
            Action::PowerOff => {
                if runtime.dry_run {
                    info!("dry-run: would power off");
                } else if let Err(error) = Command::new("/usr/bin/systemctl")
                    .args(["poweroff", "--no-block"])
                    .spawn()
                {
                    error!("cannot start poweroff: {error}");
                }
            }
            Action::Reboot => {
                if runtime.dry_run {
                    info!("dry-run: would reboot");
                } else if let Err(error) = Command::new("/usr/bin/systemctl")
                    .args(["reboot", "--no-block"])
                    .spawn()
                {
                    error!("cannot start reboot: {error}");
                }
            }
            Action::ForcePanelCycle => {
                if !runtime.dry_run {
                    let _ = runtime.session.set_mode(3).await;
                    tokio::time::sleep(Duration::from_millis(300)).await;
                    let _ = runtime.session.set_mode(0).await;
                }
            }
        }
    }
}

fn spawn_upower_watch(system: zbus::Connection, tx: mpsc::Sender<Event>) {
    tokio::spawn(async move {
        // PropertiesChanged is emitted on org.freedesktop.DBus.Properties,
        // not on the UPower interface itself.  Subscribing through a UPower
        // proxy silently misses every lid/power-source change.
        let proxy = match Proxy::new(
            &system,
            "org.freedesktop.UPower",
            "/org/freedesktop/UPower",
            "org.freedesktop.DBus.Properties",
        )
        .await
        {
            Ok(proxy) => proxy,
            Err(error) => {
                error!("cannot create UPower watcher: {error}");
                return;
            }
        };
        let mut stream = match proxy.receive_signal("PropertiesChanged").await {
            Ok(stream) => stream,
            Err(error) => {
                error!("cannot subscribe to UPower properties: {error}");
                return;
            }
        };
        while let Some(message) = stream.next().await {
            let Ok((_interface, changed, _invalidated)) =
                message
                    .body()
                    .deserialize::<(String, HashMap<String, OwnedVariant>, Vec<String>)>()
            else {
                continue;
            };
            if let Some(value) = changed.get("LidIsClosed") {
                if let Some(closed) = value_bool(value) {
                    if tx.send(Event::Lid(closed)).await.is_err() {
                        return;
                    }
                }
            }
            if let Some(value) = changed.get("OnBattery") {
                if let Some(on_battery) = value_bool(value) {
                    if tx.send(Event::PowerSource(on_battery)).await.is_err() {
                        return;
                    }
                }
            }
        }
    });
}

fn spawn_logind_watch(system: zbus::Connection, tx: mpsc::Sender<Event>) {
    tokio::spawn(async move {
        let proxy = match Proxy::new(
            &system,
            "org.freedesktop.login1",
            "/org/freedesktop/login1",
            "org.freedesktop.login1.Manager",
        )
        .await
        {
            Ok(proxy) => proxy,
            Err(error) => {
                error!("cannot create logind watcher: {error}");
                return;
            }
        };
        let mut stream = match proxy.receive_signal("PrepareForSleep").await {
            Ok(stream) => stream,
            Err(error) => {
                error!("cannot subscribe to PrepareForSleep: {error}");
                return;
            }
        };
        while let Some(message) = stream.next().await {
            if let Ok(entering) = message.body().deserialize::<bool>() {
                if tx.send(Event::PrepareForSleep(entering)).await.is_err() {
                    return;
                }
            }
        }
    });
}

fn spawn_mutter_watch(runtime: PathBuf, tx: mpsc::Sender<Event>) {
    tokio::spawn(async move {
        loop {
            let address = format!("unix:path={}", runtime.join("bus").display());
            let conn = match zbus::connection::Builder::address(address.as_str())
                .build()
                .await
            {
                Ok(conn) => conn,
                Err(error) => {
                    debug!("Mutter watcher waiting for the session bus: {error}");
                    tokio::time::sleep(Duration::from_secs(2)).await;
                    continue;
                }
            };
            let state_proxy = match Proxy::new(
                &conn,
                "org.gnome.Mutter.DisplayConfig",
                "/org/gnome/Mutter/DisplayConfig",
                "org.gnome.Mutter.DisplayConfig",
            )
            .await
            {
                Ok(proxy) => proxy,
                Err(error) => {
                    debug!("Mutter watcher cannot create state proxy: {error}");
                    tokio::time::sleep(Duration::from_secs(2)).await;
                    continue;
                }
            };
            let mode = if let Ok(mode) = state_proxy.get_property::<i32>("PowerSaveMode").await {
                Some(mode.max(0) as u32)
            } else {
                state_proxy.get_property::<u32>("PowerSaveMode").await.ok()
            };
            if let Some(mode) = mode {
                if tx.send(Event::MutterMode(mode)).await.is_err() {
                    return;
                }
            }
            let props_proxy = match Proxy::new(
                &conn,
                "org.gnome.Mutter.DisplayConfig",
                "/org/gnome/Mutter/DisplayConfig",
                "org.freedesktop.DBus.Properties",
            )
            .await
            {
                Ok(proxy) => proxy,
                Err(error) => {
                    debug!("Mutter watcher cannot create properties proxy: {error}");
                    tokio::time::sleep(Duration::from_secs(2)).await;
                    continue;
                }
            };
            let mut stream = match props_proxy.receive_signal("PropertiesChanged").await {
                Ok(stream) => stream,
                Err(error) => {
                    debug!("Mutter watcher cannot subscribe: {error}");
                    tokio::time::sleep(Duration::from_secs(2)).await;
                    continue;
                }
            };
            while let Some(message) = stream.next().await {
                let Ok((_interface, changed, _invalidated)) =
                    message
                        .body()
                        .deserialize::<(String, HashMap<String, OwnedVariant>, Vec<String>)>()
                else {
                    continue;
                };
                if let Some(value) = changed.get("PowerSaveMode") {
                    if let Some(mode) = value_mode(value) {
                        if tx.send(Event::MutterMode(mode)).await.is_err() {
                            return;
                        }
                    }
                }
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    });
}

fn spawn_power_key_watch(tx: mpsc::Sender<Event>) {
    tokio::spawn(async move {
        loop {
            let Some(path) = find_power_key() else {
                debug!("pmic_pwrkey not found yet; retrying");
                tokio::time::sleep(Duration::from_secs(2)).await;
                continue;
            };
            info!("watching power key {}", path.display());
            let tx = tx.clone();
            let result = tokio::task::spawn_blocking(move || {
                let mut device = match evdev::Device::open(&path) {
                    Ok(device) => device,
                    Err(error) => {
                        warn!("cannot open {}: {error}", path.display());
                        return;
                    }
                };
                loop {
                    match device.fetch_events() {
                        Ok(events) => {
                            for event in events {
                                if event.event_type() == evdev::EventType::KEY
                                    && event.code() == evdev::KeyCode::KEY_POWER.0
                                {
                                    let event = match event.value() {
                                        1 => Event::PowerDown,
                                        0 => Event::PowerUp,
                                        _ => continue,
                                    };
                                    if tx.blocking_send(event).is_err() {
                                        return;
                                    }
                                }
                            }
                        }
                        Err(error) => {
                            warn!("power key read failed: {error}");
                            return;
                        }
                    }
                }
            })
            .await;
            if let Err(error) = result {
                warn!("power key watcher stopped: {error}");
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    });
}

fn spawn_input_watch(tx: mpsc::Sender<Event>) {
    tokio::spawn(async move {
        let Ok(entries) = fs::read_dir("/dev/input") else {
            warn!("cannot list /dev/input");
            return;
        };
        let mut count = 0;
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if !name.starts_with("event") {
                continue;
            }
            let path = entry.path();
            let Ok(device) = evdev::Device::open(&path) else {
                continue;
            };
            if device
                .name()
                .map(|name| name == "pmic_pwrkey")
                .unwrap_or(false)
            {
                continue;
            }
            let tx = tx.clone();
            tokio::task::spawn_blocking(move || {
                let mut device = device;
                loop {
                    match device.fetch_events() {
                        Ok(events) => {
                            for event in events {
                                let meaningful = matches!(
                                    event.event_type(),
                                    evdev::EventType::KEY
                                        | evdev::EventType::RELATIVE
                                        | evdev::EventType::ABSOLUTE
                                ) && event.value() != 0;
                                if meaningful && tx.blocking_send(Event::Input).is_err() {
                                    return;
                                }
                            }
                        }
                        Err(error) => {
                            debug!("input watch ended: {error}");
                            return;
                        }
                    }
                }
            });
            count += 1;
        }
        info!("watching {count} input devices for resume cancellation");
    });
}

fn find_power_key() -> Option<PathBuf> {
    let entries = fs::read_dir("/dev/input").ok()?;
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if !name.starts_with("event") {
            continue;
        }
        let path = entry.path();
        let Ok(device) = evdev::Device::open(&path) else {
            continue;
        };
        if device
            .name()
            .map(|name| name.contains("pmic_pwrkey"))
            .unwrap_or(false)
        {
            return Some(path);
        }
    }
    None
}

fn spawn_kernel_watch(tx: mpsc::Sender<Event>, nvt_failed: Arc<AtomicBool>) {
    tokio::task::spawn_blocking(move || loop {
        let child = StdCommand::new("/usr/bin/journalctl")
            .args(["-k", "-f", "-n", "0", "-o", "cat"])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn();
        let mut child = match child {
            Ok(child) => child,
            Err(error) => {
                warn!("cannot watch the kernel log for NVT resume failures: {error}");
                std::thread::sleep(Duration::from_secs(5));
                continue;
            }
        };
        let Some(stdout) = child.stdout.take() else {
            let _ = child.wait();
            continue;
        };
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if line.contains("NVT-ts")
                && (line.contains("resume failed closed")
                    || line.contains("firmware did not reach ReK"))
            {
                nvt_failed.store(true, Ordering::SeqCst);
                if tx.blocking_send(Event::NvtResumeFailed).is_err() {
                    return;
                }
            }
        }
        let _ = child.wait();
        std::thread::sleep(Duration::from_secs(2));
    });
}

fn value_bool(value: &OwnedVariant) -> Option<bool> {
    value.downcast_ref::<bool>().ok()
}

fn value_mode(value: &OwnedVariant) -> Option<u32> {
    if let Ok(mode) = value.downcast_ref::<u32>() {
        return Some(mode);
    }
    value
        .downcast_ref::<i32>()
        .ok()
        .map(|mode| mode.max(0) as u32)
}
