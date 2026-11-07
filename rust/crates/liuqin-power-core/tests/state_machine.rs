use liuqin_power_core::*;

const T: u64 = 1_000_000;

fn make_core(config: Config) -> PowerCore {
    let mut core = PowerCore::new(config, T);
    core.initial(false, true, true, T);
    core
}

fn suspend_config() -> Config {
    Config {
        short_action: ShortAction::Suspend,
        lid_action: LidAction::Suspend,
        lid_resuspend: true,
        ..Config::default()
    }
}

#[test]
fn screen_off_first_press_only_lights_the_visible_panel() {
    let mut core = make_core(suspend_config());
    core.set_screen_lit(false);
    let actions = core.power_key(KeyPress::Short, false, GnomePowerAction::Nothing, T + 100);
    assert_eq!(actions, vec![Action::EnsureOn]);
    assert!(!core.suspend_pending);
    assert!(!core.sleeping);
    assert_eq!(core.state(T + 100), State::ScreenOff);
}

#[test]
fn screen_on_short_press_applies_short_action_once() {
    let mut core = make_core(suspend_config());
    let actions = core.power_key(KeyPress::Short, true, GnomePowerAction::Nothing, T + 100);
    assert_eq!(
        actions,
        vec![
            Action::LockSession,
            Action::Suspend {
                cause: SuspendCause::User
            }
        ]
    );
    assert!(core.suspend_pending);
    assert_eq!(core.state(T + 100), State::SuspendPending);
}

#[test]
fn short_blank_and_nothing_keep_their_meaning() {
    let mut core = make_core(Config {
        short_action: ShortAction::Blank,
        ..suspend_config()
    });
    assert_eq!(
        core.power_key(KeyPress::Short, true, GnomePowerAction::Nothing, T + 100),
        vec![Action::LockSession, Action::EnsureOff]
    );

    let mut core = make_core(Config {
        short_action: ShortAction::Nothing,
        ..suspend_config()
    });
    assert!(core
        .power_key(KeyPress::Short, true, GnomePowerAction::Nothing, T + 100)
        .is_empty());
}

#[test]
fn gnome_native_action_wins_only_when_the_screen_is_on() {
    let mut core = make_core(suspend_config());
    assert!(core
        .power_key(KeyPress::Short, true, GnomePowerAction::Other, T + 100)
        .is_empty());
    assert!(!core.suspend_pending);

    core.set_screen_lit(false);
    assert_eq!(
        core.power_key(KeyPress::Short, false, GnomePowerAction::Other, T + 200),
        vec![Action::EnsureOn]
    );
    assert!(!core.suspend_pending);
}

#[test]
fn sleeping_press_is_wake_only_even_with_suspend_short_action() {
    let mut core = make_core(suspend_config());
    core.prepare_sleep(true, T + 1000);
    let actions = core.power_key(KeyPress::Short, false, GnomePowerAction::Nothing, T + 2000);
    assert_eq!(actions, vec![Action::EnsureOn]);
    assert_eq!(core.wake_cause, WakeCause::User);
    assert!(!core.suspend_pending);
}

#[test]
fn resume_grace_suppresses_the_same_press_for_three_seconds() {
    let mut core = make_core(suspend_config());
    core.prepare_sleep(true, T + 1000);
    core.prepare_sleep(false, T + 2000);
    assert!(core.in_resume_grace(T + 4000));
    assert_eq!(
        core.power_key(KeyPress::Short, true, GnomePowerAction::Nothing, T + 4000),
        vec![Action::EnsureOn]
    );
    assert!(!core.suspend_pending);

    let actions = core.power_key(KeyPress::Short, true, GnomePowerAction::Nothing, T + 6000);
    assert_eq!(
        actions,
        vec![
            Action::LockSession,
            Action::Suspend {
                cause: SuspendCause::User
            }
        ]
    );
}

#[test]
fn closed_lid_wake_keeps_the_covered_panel_off() {
    let mut core = make_core(suspend_config());
    core.lid_changed(true, T + 100);
    core.prepare_sleep(true, T + 500);
    assert!(core
        .power_key(KeyPress::Short, false, GnomePowerAction::Nothing, T + 1000)
        .is_empty());
    assert!(core.keep_screen_off_after_resume);
    let actions = core.prepare_sleep(false, T + 1500);
    assert_eq!(actions, vec![Action::EnsureOff]);
    assert!(core.protected);
}

#[test]
fn closed_lid_awake_short_press_still_applies_the_action() {
    let mut core = make_core(Config {
        lid_action: LidAction::Blank,
        ..suspend_config()
    });
    core.lid_changed(true, T + 100);
    core.set_screen_lit(false);
    let actions = core.power_key(KeyPress::Short, false, GnomePowerAction::Nothing, T + 200);
    assert_eq!(
        actions,
        vec![
            Action::LockSession,
            Action::Suspend {
                cause: SuspendCause::User
            }
        ]
    );
}

#[test]
fn long_press_wakes_without_running_long_action() {
    let mut core = make_core(Config {
        long_action: LongAction::PowerOff,
        ..suspend_config()
    });
    core.prepare_sleep(true, T + 1000);
    assert_eq!(
        core.power_key(KeyPress::Long, false, GnomePowerAction::Nothing, T + 2000),
        vec![Action::EnsureOn]
    );
}

#[test]
fn long_press_on_a_lit_screen_runs_its_action() {
    let mut core = make_core(Config {
        long_action: LongAction::PowerOff,
        ..suspend_config()
    });
    assert_eq!(
        core.power_key(KeyPress::Long, true, GnomePowerAction::Nothing, T + 200),
        vec![Action::PowerOff]
    );

    let mut core = make_core(Config {
        long_action: LongAction::Reboot,
        ..suspend_config()
    });
    assert_eq!(
        core.power_key(KeyPress::Long, true, GnomePowerAction::Nothing, T + 200),
        vec![Action::Reboot]
    );
}

#[test]
fn lid_blank_and_suspend_use_the_shared_lock_path() {
    let mut core = make_core(Config {
        lid_action: LidAction::Blank,
        ..suspend_config()
    });
    assert_eq!(
        core.lid_changed(true, T + 100),
        vec![Action::LockSession, Action::EnsureOff]
    );
    assert_eq!(core.lid_changed(false, T + 200), vec![Action::EnsureOn]);

    let mut core = make_core(suspend_config());
    assert_eq!(
        core.lid_changed(true, T + 100),
        vec![
            Action::LockSession,
            Action::Suspend {
                cause: SuspendCause::Lid
            }
        ]
    );
}

#[test]
fn closed_lid_resume_protects_the_panel_and_can_resuspend() {
    let mut core = make_core(suspend_config());
    core.lid_changed(true, T + 100);
    core.prepare_sleep(true, T + 500);
    let actions = core.prepare_sleep(false, T + 1500);
    assert_eq!(actions, vec![Action::EnsureOff]);
    assert!(core.protected);
    assert_eq!(core.retry_at_ms, Some(T + 21_500));
    assert_eq!(core.timer(T + 4_500), vec![Action::EnsureOff]);
    let actions = core.timer(T + 21_500);
    assert_eq!(
        actions,
        vec![
            Action::LockSession,
            Action::Suspend {
                cause: SuspendCause::Retry
            }
        ]
    );
    assert_eq!(core.retry_count, 1);
}

#[test]
fn user_input_and_ac_power_cancel_automatic_resuspend() {
    let mut core = make_core(suspend_config());
    core.lid_changed(true, T + 100);
    core.prepare_sleep(true, T + 500);
    core.prepare_sleep(false, T + 1500);
    core.user_input(T + 3000);
    assert!(core.retry_at_ms.is_none());
    assert!(!core
        .timer(T + 22_000)
        .iter()
        .any(|action| matches!(action, Action::Suspend { .. })));

    let mut core = make_core(suspend_config());
    core.lid_changed(true, T + 100);
    core.prepare_sleep(true, T + 500);
    core.prepare_sleep(false, T + 1500);
    core.power_source(false);
    assert!(core.retry_at_ms.is_none());
}

#[test]
fn quick_resume_loop_is_bounded() {
    let mut core = make_core(suspend_config());
    for index in 0..3 {
        core.note_resuspend_issued(T + 500 + index * 5000);
        core.prepare_sleep(true, T + 1000 + index * 5000);
        core.prepare_sleep(false, T + 2000 + index * 5000);
    }
    assert!(core.stopped);
}

#[test]
fn config_parser_falls_back_per_key() {
    let config = Config::parse(
        "SHORT_ACTION=blank\nLONG_ACTION=poweroff\nLID_ACTION=nothing\nLID_RESUSPEND=0\n",
    );
    assert_eq!(config.short_action, ShortAction::Blank);
    assert_eq!(config.long_action, LongAction::PowerOff);
    assert_eq!(config.lid_action, LidAction::Nothing);
    assert!(!config.lid_resuspend);

    let config = Config::parse("SHORT_ACTION=bogus\nLID_ACTION=suspend\n");
    assert_eq!(config.short_action, ShortAction::Suspend);
    assert_eq!(config.lid_action, LidAction::Suspend);
}

#[test]
fn gnome_gsettings_value_is_parsed_conservatively() {
    assert_eq!(
        GnomePowerAction::from_gsettings("'nothing'\n"),
        GnomePowerAction::Nothing
    );
    assert_eq!(
        GnomePowerAction::from_gsettings("suspend\n"),
        GnomePowerAction::Other
    );
}

#[test]
fn closed_lid_display_fixes_are_rate_limited() {
    let mut core = make_core(Config {
        lid_action: LidAction::Blank,
        lid_resuspend: false,
        ..suspend_config()
    });
    core.lid_changed(true, T + 100);
    core.display_changed(0, T + 5000);
    assert_eq!(core.fix_at_ms, Some(T + 5000));
    assert_eq!(core.timer(T + 5000), vec![Action::EnsureOff]);
    for failure in 0..3 {
        core.note_fix_result(false, T + 6000 + failure * 1000);
    }
    assert!(core.fix_disabled);
}

#[test]
fn startup_with_a_closed_lid_arms_one_grace_suspend() {
    let mut core = PowerCore::new(suspend_config(), T);
    assert_eq!(core.initial(true, true, false, T), vec![Action::EnsureOff]);
    assert_eq!(core.startup_suspend_at_ms, Some(T + STARTUP_GRACE_MS));
    assert_eq!(
        core.timer(T + STARTUP_GRACE_MS),
        vec![
            Action::LockSession,
            Action::Suspend {
                cause: SuspendCause::Startup
            }
        ]
    );
    assert!(core.startup_suspend_at_ms.is_none());
}

#[test]
fn failed_suspend_blanks_a_closed_lid_and_retries() {
    let mut core = make_core(suspend_config());
    core.lid_changed(true, T + 100);
    core.begin_suspend(SuspendCause::Lid, T + 200);
    let actions = core.timer(T + 200 + SUSPEND_CONFIRM_MS);
    assert_eq!(actions, vec![Action::EnsureOff]);
    assert!(core.retry_at_ms.is_some());
    assert!(!core.suspend_pending);
}

#[test]
fn failed_open_lid_suspend_restores_a_dark_screen_after_five_seconds() {
    let mut core = make_core(suspend_config());
    core.set_screen_lit(false);
    core.begin_suspend(SuspendCause::User, T + 100);
    let actions = core.timer(T + 100 + SUSPEND_CONFIRM_MS);
    assert!(actions.is_empty());
    assert_eq!(core.failed_display_at_ms, Some(T + 8_100 + 5_000));
    assert_eq!(core.timer(T + 13_100), vec![Action::EnsureOff]);
}

#[test]
fn recent_power_key_marker_suppresses_startup_reblank_and_suspend() {
    let mut core = PowerCore::new(suspend_config(), T);
    core.user_override = true;
    assert!(core.initial(true, true, false, T).is_empty());
    assert!(!core.protected);
    assert!(core.startup_suspend_at_ms.is_none());
}

#[test]
fn the_power_key_that_wakes_cancels_an_automatic_resuspend_window() {
    let mut core = make_core(suspend_config());
    core.lid_changed(true, T + 100);
    core.prepare_sleep(true, T + 500);
    core.prepare_sleep(false, T + 1500);
    assert!(core.retry_at_ms.is_some());
    let actions = core.power_key(KeyPress::Short, false, GnomePowerAction::Nothing, T + 2000);
    assert!(actions.is_empty());
    assert!(core.retry_at_ms.is_none());
    assert_eq!(core.wake_cause, WakeCause::User);
    assert_eq!(core.last_input_ms, Some(T + 2000));
}

#[test]
fn a_screen_off_wake_suppresses_a_second_press_for_three_seconds() {
    let mut core = make_core(suspend_config());
    core.set_screen_lit(false);
    assert_eq!(
        core.power_key(KeyPress::Short, false, GnomePowerAction::Nothing, T + 100),
        vec![Action::EnsureOn]
    );
    assert_eq!(
        core.power_key(KeyPress::Short, true, GnomePowerAction::Nothing, T + 1_000),
        vec![Action::EnsureOn]
    );
    assert!(!core.suspend_pending);
    let actions = core.power_key(KeyPress::Short, true, GnomePowerAction::Nothing, T + 3_101);
    assert_eq!(
        actions,
        vec![
            Action::LockSession,
            Action::Suspend {
                cause: SuspendCause::User
            }
        ]
    );
}

#[test]
fn opening_the_lid_suppresses_an_immediate_power_press() {
    let mut core = make_core(suspend_config());
    core.lid_changed(true, T + 100);
    core.lid_changed(false, T + 200);
    assert_eq!(
        core.power_key(KeyPress::Short, true, GnomePowerAction::Nothing, T + 1_000),
        vec![Action::EnsureOn]
    );
    assert!(!core.suspend_pending);
}
