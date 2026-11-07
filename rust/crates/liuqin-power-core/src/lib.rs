//! Pure power-key, lid and resume state machine for the Xiaomi Pad 6 Pro.
//!
//! This crate deliberately contains no I/O and no clock.  The daemon supplies
//! a CLOCK_BOOTTIME millisecond value (which keeps advancing during suspend)
//! and executes the returned actions.  Keeping the decisions pure makes the
//! "screen first" rules testable without touching a real desktop.

#![forbid(unsafe_code)]

/// A user-visible action setting from `/etc/liuqin/power-policy.conf`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ShortAction {
    Blank,
    Suspend,
    Nothing,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LongAction {
    Nothing,
    PowerOff,
    Reboot,
    Suspend,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LidAction {
    Blank,
    Suspend,
    Nothing,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Config {
    pub short_action: ShortAction,
    pub long_action: LongAction,
    pub lid_action: LidAction,
    pub lid_resuspend: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            short_action: ShortAction::Suspend,
            long_action: LongAction::Nothing,
            lid_action: LidAction::Suspend,
            lid_resuspend: true,
        }
    }
}

impl Config {
    /// Parse the four keys from the simple `KEY=value` policy file.
    ///
    /// Unknown or malformed values fall back per key, never as a whole file.
    /// The daemon logs the result; the parser itself stays side-effect free.
    pub fn parse(text: &str) -> Self {
        let mut config = Self::default();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            let value = value.trim();
            match key.trim() {
                "SHORT_ACTION" => {
                    config.short_action = match value {
                        "blank" => ShortAction::Blank,
                        "suspend" => ShortAction::Suspend,
                        "nothing" => ShortAction::Nothing,
                        _ => config.short_action,
                    };
                }
                "LONG_ACTION" => {
                    config.long_action = match value {
                        "nothing" => LongAction::Nothing,
                        "poweroff" | "power-off" => LongAction::PowerOff,
                        "reboot" => LongAction::Reboot,
                        "suspend" => LongAction::Suspend,
                        _ => config.long_action,
                    };
                }
                "LID_ACTION" => {
                    config.lid_action = match value {
                        "blank" => LidAction::Blank,
                        "suspend" => LidAction::Suspend,
                        "nothing" => LidAction::Nothing,
                        _ => config.lid_action,
                    };
                }
                "LID_RESUSPEND" => {
                    config.lid_resuspend = match value {
                        "1" | "true" | "yes" | "on" => true,
                        "0" | "false" | "no" | "off" => false,
                        _ => config.lid_resuspend,
                    };
                }
                _ => {}
            }
        }
        config
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum GnomePowerAction {
    Nothing,
    Other,
}

impl GnomePowerAction {
    pub fn from_gsettings(value: &str) -> Self {
        if value.trim().trim_matches('\'').trim() == "nothing" {
            Self::Nothing
        } else {
            Self::Other
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum KeyPress {
    Short,
    Long,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SuspendCause {
    Lid,
    User,
    Retry,
    Startup,
}

impl SuspendCause {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Lid => "lid",
            Self::User => "user",
            Self::Retry => "retry",
            Self::Startup => "startup",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WakeCause {
    User,
    Scheduled,
    Abnormal,
    Unknown,
    None,
}

impl WakeCause {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::User => "user",
            Self::Scheduled => "scheduled",
            Self::Abnormal => "abnormal",
            Self::Unknown => "unknown",
            Self::None => "none",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum State {
    Awake,
    ScreenOff,
    SuspendPending,
    Asleep,
    ResumeGrace,
    RetryWait,
    Blocked,
}

impl State {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Awake => "AWAKE",
            Self::ScreenOff => "SCREEN_OFF",
            Self::SuspendPending => "SUSPEND_PENDING",
            Self::Asleep => "ASLEEP",
            Self::ResumeGrace => "RESUME_GRACE",
            Self::RetryWait => "RETRY_WAIT",
            Self::Blocked => "BLOCKED",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Action {
    EnsureOn,
    EnsureOff,
    LockSession,
    Suspend { cause: SuspendCause },
    PowerOff,
    Reboot,
    ForcePanelCycle,
}

pub const RESUME_GRACE_MS: u64 = 3_000;
pub const RESUME_CONFIRM_MS: u64 = 3_000;
pub const RESUSPEND_DELAY_MS: u64 = 20_000;
pub const OPEN_LID_RETRY_MS: u64 = 10_000;
pub const SUSPEND_CONFIRM_MS: u64 = 8_000;
pub const STARTUP_GRACE_MS: u64 = 5_000;
pub const LID_DEBOUNCE_MS: u64 = 300;
pub const BAD_POWER_KEY_DEBOUNCE_MS: u64 = 40;
pub const FIX_INTERVAL_MS: u64 = 1_000;
pub const MAX_FIX_FAILURES: u32 = 3;
pub const QUICK_RESUME_MS: u64 = 30_000;
pub const RATE_WINDOW_MS: u64 = 1_800_000;
pub const RATE_LIMIT: usize = 3;

#[derive(Clone, Debug)]
pub struct PowerCore {
    pub config: Config,
    pub lid_closed: bool,
    pub on_battery: bool,
    pub sleeping: bool,
    pub suspend_pending: bool,
    pub suspend_confirm_at_ms: Option<u64>,
    pub suspend_cause: Option<SuspendCause>,
    pub last_resume_ms: Option<u64>,
    pub wake_cause: WakeCause,
    pub retry_at_ms: Option<u64>,
    pub retry_count: u32,
    pub blocked_reason: Option<String>,
    pub user_override: bool,
    pub input_seen: bool,
    pub last_input_ms: Option<u64>,
    pub screen_lit: bool,
    pub power_save_mode: Option<u32>,
    pub pre_suspend_screen_lit: bool,
    pub sleep_started_ms: Option<u64>,
    pub last_sleep_ms: u64,
    pub protected: bool,
    pub fix_at_ms: Option<u64>,
    pub last_fix_ms: Option<u64>,
    pub fix_failures: u32,
    pub fix_disabled: bool,
    pub allow_open_lid_resuspend: bool,
    pub resume_cycle: bool,
    pub stopped: bool,
    pub startup_suspend_at_ms: Option<u64>,
    pub keep_screen_off_after_resume: bool,
    pub last_lid_change_ms: Option<u64>,
    pub attempts: Vec<u64>,
    pub quick_resumes: Vec<u64>,
    pub suppress_next_power_key_until_ms: u64,
    pub failed_display_at_ms: Option<u64>,
}

impl PowerCore {
    pub fn new(config: Config, now_ms: u64) -> Self {
        Self {
            config,
            lid_closed: false,
            on_battery: false,
            sleeping: false,
            suspend_pending: false,
            suspend_confirm_at_ms: None,
            suspend_cause: None,
            last_resume_ms: None,
            wake_cause: WakeCause::None,
            retry_at_ms: None,
            retry_count: 0,
            blocked_reason: None,
            user_override: false,
            input_seen: false,
            last_input_ms: None,
            screen_lit: false,
            power_save_mode: None,
            pre_suspend_screen_lit: false,
            sleep_started_ms: None,
            last_sleep_ms: 0,
            protected: false,
            fix_at_ms: None,
            last_fix_ms: None,
            fix_failures: 0,
            fix_disabled: false,
            allow_open_lid_resuspend: false,
            resume_cycle: false,
            stopped: false,
            startup_suspend_at_ms: None,
            keep_screen_off_after_resume: false,
            last_lid_change_ms: Some(now_ms),
            attempts: Vec::new(),
            quick_resumes: Vec::new(),
            suppress_next_power_key_until_ms: 0,
            failed_display_at_ms: None,
        }
    }

    pub fn state(&self, now_ms: u64) -> State {
        if self.sleeping {
            return State::Asleep;
        }
        if self.suspend_pending {
            return State::SuspendPending;
        }
        if self.in_resume_grace(now_ms) {
            return State::ResumeGrace;
        }
        if self.retry_at_ms.is_some() {
            return State::RetryWait;
        }
        if self.blocked_reason.is_some() {
            return State::Blocked;
        }
        if !self.screen_lit {
            return State::ScreenOff;
        }
        State::Awake
    }

    pub fn in_resume_grace(&self, now_ms: u64) -> bool {
        self.last_resume_ms
            .map(|at| now_ms.saturating_sub(at) <= RESUME_GRACE_MS)
            .unwrap_or(false)
    }

    pub fn in_startup_grace(&self, now_ms: u64) -> bool {
        self.last_lid_change_ms
            .map(|at| now_ms.saturating_sub(at) <= STARTUP_GRACE_MS)
            .unwrap_or(false)
    }

    /// First snapshot after startup.  A closed lid gets display protection
    /// immediately; the daemon separately applies the startup suspend grace.
    pub fn initial(
        &mut self,
        lid_closed: bool,
        on_battery: bool,
        screen_lit: bool,
        now_ms: u64,
    ) -> Vec<Action> {
        self.lid_closed = lid_closed;
        self.on_battery = on_battery;
        self.screen_lit = screen_lit;
        self.last_lid_change_ms = Some(now_ms);
        if self.user_override {
            self.protected = false;
            return Vec::new();
        }
        if !lid_closed {
            return Vec::new();
        }
        if self.config.lid_action == LidAction::Nothing {
            return Vec::new();
        }
        self.protected = true;
        self.last_fix_ms = Some(now_ms);
        if self.config.lid_action == LidAction::Suspend && !self.user_override {
            self.startup_suspend_at_ms = Some(now_ms + STARTUP_GRACE_MS);
        }
        vec![Action::EnsureOff]
    }

    pub fn skip_startup_suspend(&mut self) {
        self.startup_suspend_at_ms = None;
    }

    /// Power-key decision.  `screen_lit` and `gnome_action` must be captured
    /// when the key went down, before Mutter sees the same press and possibly
    /// turns the panel on.  This is the core fix for "wake then immediately
    /// suspend again".
    pub fn power_key(
        &mut self,
        press: KeyPress,
        screen_lit_at_press: bool,
        gnome_action: GnomePowerAction,
        now_ms: u64,
    ) -> Vec<Action> {
        self.screen_lit = screen_lit_at_press;

        // The key that wakes the device owns this cycle.  If logind has not
        // delivered PrepareForSleep(false) yet, handle the press as wake-only
        // instead of running SHORT_ACTION.
        if self.sleeping {
            self.keep_screen_off_after_resume = self.lid_closed;
            return self.wake_only_actions(now_ms);
        }
        if now_ms < self.suppress_next_power_key_until_ms || self.in_resume_grace(now_ms) {
            return self.wake_only_actions(now_ms);
        }
        if self.suspend_pending {
            return Vec::new();
        }

        match press {
            KeyPress::Short => {
                if !screen_lit_at_press {
                    if self.lid_closed {
                        // The panel is covered.  Do not light it, but an
                        // already-awake tablet may still apply the short
                        // action (normally suspend) so a covered screen does
                        // not stay awake forever.
                        return self.apply_short_action(gnome_action, now_ms);
                    }
                    self.note_wake(now_ms);
                    return vec![Action::EnsureOn];
                }
                self.user_override = true;
                self.protected = false;
                self.cancel_retry("power key");
                self.apply_short_action(gnome_action, now_ms)
            }
            KeyPress::Long => {
                if !screen_lit_at_press {
                    if self.lid_closed {
                        return Vec::new();
                    }
                    self.note_wake(now_ms);
                    return vec![Action::EnsureOn];
                }
                self.user_override = true;
                self.protected = false;
                self.cancel_retry("power key long press");
                match self.config.long_action {
                    LongAction::Nothing => Vec::new(),
                    LongAction::PowerOff => vec![Action::PowerOff],
                    LongAction::Reboot => vec![Action::Reboot],
                    LongAction::Suspend => {
                        self.begin_suspend(SuspendCause::User, now_ms);
                        vec![
                            Action::LockSession,
                            Action::Suspend {
                                cause: SuspendCause::User,
                            },
                        ]
                    }
                }
            }
        }
    }

    fn note_wake(&mut self, now_ms: u64) {
        // The press that wakes the tablet owns this cycle.  Do not let an
        // automatic re-suspend window turn it into another sleep.
        self.wake_cause = WakeCause::User;
        self.user_override = true;
        self.protected = false;
        self.last_input_ms = Some(now_ms);
        self.cancel_retry("power key wake");
        // Suppress the same key for three seconds after a screen-off wake,
        // even when the system itself stayed awake.  Do not extend the window
        // on every ignored repeat press.
        if now_ms >= self.suppress_next_power_key_until_ms {
            self.suppress_next_power_key_until_ms = now_ms + RESUME_GRACE_MS;
        }
    }

    fn wake_only_actions(&mut self, now_ms: u64) -> Vec<Action> {
        self.note_wake(now_ms);
        if self.lid_closed {
            Vec::new()
        } else {
            vec![Action::EnsureOn]
        }
    }

    fn apply_short_action(&mut self, gnome_action: GnomePowerAction, now_ms: u64) -> Vec<Action> {
        // GNOME's native setting is the final authority for a short press on
        // an already-lit screen.  Screen-off wake has already been handled
        // above and never reaches this branch.
        if gnome_action == GnomePowerAction::Other {
            return Vec::new();
        }
        match self.config.short_action {
            ShortAction::Blank => vec![Action::LockSession, Action::EnsureOff],
            ShortAction::Suspend => {
                self.begin_suspend(SuspendCause::User, now_ms);
                vec![
                    Action::LockSession,
                    Action::Suspend {
                        cause: SuspendCause::User,
                    },
                ]
            }
            ShortAction::Nothing => Vec::new(),
        }
    }

    pub fn lid_changed(&mut self, closed: bool, now_ms: u64) -> Vec<Action> {
        if closed == self.lid_closed {
            return Vec::new();
        }
        self.lid_closed = closed;
        self.last_lid_change_ms = Some(now_ms);
        if !self.sleeping {
            self.suspend_pending = false;
            self.suspend_confirm_at_ms = None;
            self.suspend_cause = None;
        }
        self.user_override = false;
        self.input_seen = false;
        self.resume_cycle = false;
        self.allow_open_lid_resuspend = false;
        self.retry_count = 0;
        self.stopped = false;
        self.blocked_reason = None;
        self.fix_disabled = false;
        self.fix_failures = 0;
        self.retry_at_ms = None;
        self.fix_at_ms = None;
        self.failed_display_at_ms = None;
        self.startup_suspend_at_ms = None;
        if closed {
            if self.config.lid_action == LidAction::Nothing {
                self.protected = false;
                return Vec::new();
            }
            self.protected = true;
            self.last_fix_ms = Some(now_ms);
            match self.config.lid_action {
                LidAction::Blank => vec![Action::LockSession, Action::EnsureOff],
                LidAction::Suspend => {
                    self.begin_suspend(SuspendCause::Lid, now_ms);
                    vec![
                        Action::LockSession,
                        Action::Suspend {
                            cause: SuspendCause::Lid,
                        },
                    ]
                }
                LidAction::Nothing => Vec::new(),
            }
        } else {
            self.protected = false;
            if self.config.lid_action != LidAction::Nothing {
                self.suppress_next_power_key_until_ms = now_ms + RESUME_GRACE_MS;
                vec![Action::EnsureOn]
            } else {
                Vec::new()
            }
        }
    }

    pub fn begin_suspend(&mut self, cause: SuspendCause, now_ms: u64) {
        self.suspend_pending = true;
        self.suspend_cause = Some(cause);
        self.suspend_confirm_at_ms = Some(now_ms + SUSPEND_CONFIRM_MS);
        self.retry_at_ms = None;
        self.pre_suspend_screen_lit = self.screen_lit;
    }

    pub fn prepare_sleep(&mut self, entering: bool, now_ms: u64) -> Vec<Action> {
        if entering {
            self.sleep_started_ms = Some(now_ms);
            self.last_resume_ms = None;
            self.wake_cause = WakeCause::Unknown;
            self.allow_open_lid_resuspend = false;
            self.sleeping = true;
            self.protected = false;
            self.resume_cycle = false;
            self.suspend_pending = false;
            self.suspend_confirm_at_ms = None;
            self.retry_at_ms = None;
            self.fix_at_ms = None;
            self.failed_display_at_ms = None;
            self.keep_screen_off_after_resume = false;
            return Vec::new();
        }

        let slept_ms = self
            .sleep_started_ms
            .map(|started| now_ms.saturating_sub(started))
            .unwrap_or(0);
        self.sleep_started_ms = None;
        self.last_sleep_ms = slept_ms;
        if slept_ms > QUICK_RESUME_MS {
            self.retry_count = 0;
        }
        self.last_resume_ms = Some(now_ms);
        self.suppress_next_power_key_until_ms = now_ms + RESUME_GRACE_MS;
        self.blocked_reason = None;
        self.sleeping = false;
        self.suspend_pending = false;
        self.suspend_confirm_at_ms = None;
        self.user_override = false;
        self.input_seen = false;
        self.fix_disabled = false;
        self.fix_failures = 0;
        self.fix_at_ms = None;
        self.retry_at_ms = None;
        self.note_resume(now_ms);

        let mut actions = Vec::new();
        if self.lid_closed && self.config.lid_action != LidAction::Nothing {
            self.protected = true;
            self.last_fix_ms = Some(now_ms);
            actions.push(Action::EnsureOff);
            self.fix_at_ms = Some(now_ms + RESUME_CONFIRM_MS);
        } else {
            self.protected = false;
            if self.keep_screen_off_after_resume {
                actions.push(Action::EnsureOff);
            } else if self.config.lid_action != LidAction::Nothing {
                actions.push(Action::EnsureOn);
            }
        }
        self.keep_screen_off_after_resume = false;
        self.resume_cycle = true;
        if self.can_resuspend() {
            self.retry_at_ms = Some(now_ms + RESUSPEND_DELAY_MS);
        }
        actions
    }

    pub fn note_resume(&mut self, now_ms: u64) {
        if let Some(last) = self.attempts.last().copied() {
            if now_ms.saturating_sub(last) <= QUICK_RESUME_MS {
                self.quick_resumes.push(now_ms);
            } else {
                self.quick_resumes.clear();
            }
        }
        self.quick_resumes
            .retain(|at| now_ms.saturating_sub(*at) <= RATE_WINDOW_MS);
        if self.quick_resumes.len() >= RATE_LIMIT {
            self.stopped = true;
        }
    }

    pub fn note_resuspend_issued(&mut self, now_ms: u64) {
        self.attempts.push(now_ms);
        self.retry_count = self.retry_count.saturating_add(1);
        self.allow_open_lid_resuspend = false;
        self.resume_cycle = false;
        self.retry_at_ms = None;
    }

    pub fn can_resuspend(&self) -> bool {
        self.config.lid_resuspend
            && self.resume_cycle
            && self.on_battery
            && (self.lid_closed || self.allow_open_lid_resuspend)
            && self.config.lid_action != LidAction::Nothing
            && self.blocked_reason.is_none()
            && !self.sleeping
            && !self.suspend_pending
            && !self.user_override
            && !self.input_seen
            && !self.stopped
    }

    pub fn note_abnormal_short_wake(&mut self, now_ms: u64) -> bool {
        if self.last_sleep_ms > QUICK_RESUME_MS {
            return false;
        }
        if self.config.lid_resuspend
            && self.on_battery
            && self.config.lid_action != LidAction::Nothing
            && !self.lid_closed
            && !self.user_override
            && !self.input_seen
            && !self.stopped
        {
            self.resume_cycle = true;
            self.allow_open_lid_resuspend = true;
            self.retry_at_ms = Some(now_ms + OPEN_LID_RETRY_MS);
            true
        } else {
            false
        }
    }

    pub fn user_input(&mut self, now_ms: u64) {
        self.input_seen = true;
        self.last_input_ms = Some(now_ms);
        self.allow_open_lid_resuspend = false;
        self.failed_display_at_ms = None;
        self.blocked_reason = None;
        self.retry_count = 0;
        if self.retry_at_ms.is_some() {
            self.retry_at_ms = None;
        }
    }

    pub fn power_source(&mut self, on_battery: bool) {
        self.on_battery = on_battery;
        if !on_battery {
            self.retry_at_ms = None;
            self.allow_open_lid_resuspend = false;
            self.blocked_reason = None;
        }
    }

    pub fn set_screen_lit(&mut self, lit: bool) {
        self.screen_lit = lit;
    }

    pub fn display_changed(&mut self, mode: u32, now_ms: u64) {
        self.power_save_mode = Some(mode);
        if mode == 3 {
            self.screen_lit = false;
        }
        if mode == 3 {
            return;
        }
        if !self.lid_closed || !self.protected || self.fix_disabled {
            return;
        }
        if self.fix_at_ms.is_none() {
            let earliest = self
                .last_fix_ms
                .map(|at| at + FIX_INTERVAL_MS)
                .unwrap_or(now_ms);
            self.fix_at_ms = Some(now_ms.max(earliest));
        }
    }

    pub fn note_fix_result(&mut self, ok: bool, now_ms: u64) {
        if ok {
            self.fix_failures = 0;
            return;
        }
        if !self.protected {
            return;
        }
        self.fix_failures = self.fix_failures.saturating_add(1);
        if self.fix_failures >= MAX_FIX_FAILURES {
            self.fix_disabled = true;
            self.fix_at_ms = None;
        } else {
            self.fix_at_ms = Some(now_ms + FIX_INTERVAL_MS);
        }
    }

    pub fn set_blocked(&mut self, reason: Option<String>) {
        self.blocked_reason = reason;
        if self.blocked_reason.is_some() {
            self.retry_at_ms = None;
        }
    }

    pub fn set_config(&mut self, config: Config) {
        let old = self.config;
        self.config = config;
        if old.lid_action != config.lid_action && config.lid_action == LidAction::Nothing {
            self.protected = false;
            self.fix_at_ms = None;
        }
        if !config.lid_resuspend {
            self.retry_at_ms = None;
            self.allow_open_lid_resuspend = false;
        }
    }

    pub fn suspend_failed(&mut self, now_ms: u64) -> Vec<Action> {
        self.suspend_pending = false;
        self.suspend_confirm_at_ms = None;
        self.suspend_cause = None;
        let mut actions = Vec::new();
        if self.lid_closed {
            self.protected = true;
            self.last_fix_ms = Some(now_ms);
            actions.push(Action::EnsureOff);
            let _ = self.schedule_retry("suspend failed", now_ms);
        } else if !self.pre_suspend_screen_lit {
            // The screen was already off before the failed suspend.  Restore
            // that state after a short grace so a user who is currently using
            // the tablet is not surprised by a sudden blank.
            self.failed_display_at_ms = Some(now_ms + 5_000);
        }
        actions
    }

    pub fn schedule_retry(&mut self, _reason: &str, now_ms: u64) -> bool {
        if self.retry_at_ms.is_some() {
            return false;
        }
        if self.blocked_reason.is_some()
            || !self.config.lid_resuspend
            || !self.on_battery
            || !self.lid_closed
            || self.config.lid_action == LidAction::Nothing
            || self.stopped
            || self.user_override
            || self.input_seen
        {
            return false;
        }
        self.resume_cycle = true;
        self.retry_at_ms = Some(now_ms + RESUSPEND_DELAY_MS);
        true
    }

    pub fn cancel_retry(&mut self, _reason: &str) {
        self.retry_at_ms = None;
        self.retry_count = 0;
        self.allow_open_lid_resuspend = false;
    }

    /// Process deadlines.  The daemon calls this once per second and before
    /// rebuilding its sleep timer.
    pub fn timer(&mut self, now_ms: u64) -> Vec<Action> {
        let mut actions = Vec::new();

        if let Some(at) = self.startup_suspend_at_ms {
            if now_ms >= at {
                self.startup_suspend_at_ms = None;
                if self.lid_closed
                    && !self.sleeping
                    && !self.suspend_pending
                    && self.config.lid_action == LidAction::Suspend
                    && !self.user_override
                {
                    self.begin_suspend(SuspendCause::Startup, now_ms);
                    actions.push(Action::LockSession);
                    actions.push(Action::Suspend {
                        cause: SuspendCause::Startup,
                    });
                }
            }
        }

        if let Some(at) = self.suspend_confirm_at_ms {
            if now_ms >= at {
                if self.suspend_pending {
                    actions.extend(self.suspend_failed(now_ms));
                } else {
                    self.suspend_confirm_at_ms = None;
                }
            }
        }

        if let Some(at) = self.fix_at_ms {
            if now_ms >= at {
                self.fix_at_ms = None;
                if self.lid_closed && self.protected && !self.fix_disabled {
                    self.last_fix_ms = Some(now_ms);
                    actions.push(Action::EnsureOff);
                }
            }
        }

        if let Some(at) = self.failed_display_at_ms {
            if now_ms >= at {
                self.failed_display_at_ms = None;
                let recent_input = self
                    .last_input_ms
                    .map(|input| now_ms.saturating_sub(input) < 5_000)
                    .unwrap_or(false);
                if !self.lid_closed && !self.sleeping && !recent_input {
                    actions.push(Action::EnsureOff);
                }
            }
        }

        if let Some(at) = self.retry_at_ms {
            if now_ms >= at {
                self.retry_at_ms = None;
                if self.can_resuspend() {
                    self.note_resuspend_issued(now_ms);
                    self.begin_suspend(SuspendCause::Retry, now_ms);
                    actions.push(Action::LockSession);
                    actions.push(Action::Suspend {
                        cause: SuspendCause::Retry,
                    });
                }
            }
        }

        actions
    }

    pub fn next_deadline_ms(&self) -> Option<u64> {
        [
            self.startup_suspend_at_ms,
            self.suspend_confirm_at_ms,
            self.fix_at_ms,
            self.retry_at_ms,
            self.failed_display_at_ms,
            self.last_resume_ms
                .map(|at| at.saturating_add(RESUME_GRACE_MS)),
        ]
        .into_iter()
        .flatten()
        .min()
    }
}
