#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Decode a sealed early-wake recording offline. Never identify a physical waker.

Sequence means recorder observation order, not hardware arrival order. Raw
counter seconds are usable only after matching a unique observer pre/post pair
and cross-checking its dual clocks AND APSS residency. No archive extraction.
"""
import argparse
import bisect
import json
import re
import tarfile
from pathlib import Path

PHASES = ("CYCLE_BEGIN", "CPU_OFF_BEGIN", "CPUS_OFF", "IRQS_OFF",
          "SYSCORE_SUSPENDED", "ENTER_CALL", "ENTER_RETURN", "ENTER_SKIPPED",
          "SYSCORE_RESUMED", "IRQ_ENABLE_BEGIN", "IRQ_ENABLE_DONE",
          "CPU_ON_BEGIN", "CPUS_ON", "RESUME_NOIRQ_BEGIN", "DEVICES_RESUMED",
          "CYCLE_END", "ERROR")
NORMAL = tuple(p for p in PHASES if p not in ("ENTER_SKIPPED", "ERROR"))
MEMBER = re.compile(r"var/lib/liuqin-suspend-log/events/([A-Za-z0-9-]+)/(pre|post)\.json\Z")


def integer(value, name, low=0, high=2**64 - 1):
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f"invalid integer {name}: {value!r}")
    return value


def signed(value):
    return value - 2**32 if value >= 2**31 else value


def parse_status(text):
    result = {}
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if not sep or not key or key in result:
            raise ValueError("malformed/duplicate status key")
        result[key] = value
    return result


def number(status, name):
    value = status.get(name, "")
    if not re.fullmatch(r"[0-9]+", value):
        raise ValueError(f"missing/non-numeric status {name}")
    return integer(int(value), name)


def read_observers(path):
    """Read only regular, bounded, known pre/post files into memory."""
    pairs = {}
    size = 0
    seen = set()
    with tarfile.open(path, "r:gz") as archive:
        for index, member in enumerate(archive):
            if index > 20000:
                raise ValueError("too many archive entries")
            match = MEMBER.fullmatch(member.name)
            if not match:
                continue
            if not member.isfile() or member.size > 4 * 1024**2:
                raise ValueError("observer is not a bounded regular file")
            if member.name in seen:
                raise ValueError("duplicate observer member")
            seen.add(member.name)
            size += member.size
            if size > 64 * 1024**2:
                raise ValueError("observer archive exceeds memory budget")
            value = json.load(archive.extractfile(member))
            if not isinstance(value, dict):
                raise ValueError("observer must be an object")
            event_id, phase = match.groups()
            pairs.setdefault(event_id, {})[phase] = value
    return pairs


def apss(snapshot):
    text = snapshot.get("qcom_stats", {}).get("apss", "")
    values = {}
    for key in ("Count", "Last Entered At", "Last Exited At", "Accumulated Duration"):
        match = re.search(rf"^{key}:\s*([0-9]+)\s*$", text, re.M)
        if not match:
            raise ValueError("missing APSS counter")
        values[key] = int(match[1])
    return values


def observer_metrics(pre, post, call, returned, rate, build_id):
    if not pre.get("boot_id") or pre.get("boot_id") != post.get("boot_id"):
        raise ValueError("observer boot mismatch/missing")
    if pre.get("build_id") != build_id or post.get("build_id") != build_id:
        raise ValueError("observer Build ID mismatch/missing")
    b0, b1 = (integer(x.get("collected_boottime_ns"), "observer boottime")
              for x in (pre, post))
    m0, m1 = (integer(x.get("collected_monotonic_ns"), "observer monotonic")
              for x in (pre, post))
    window, awake = (b1 - b0) / 1e9, (m1 - m0) / 1e9
    residency = window - awake
    if awake < 0 or residency <= 0:
        raise ValueError("observer clocks inconsistent/no positive residency")
    a0, a1 = apss(pre), apss(post)
    entered, exited = a1["Last Entered At"], a1["Last Exited At"]
    duration = exited - entered
    if (a1["Count"] - a0["Count"] != 1 or duration <= 0 or
            a1["Accumulated Duration"] - a0["Accumulated Duration"] != duration):
        raise ValueError("APSS is not a single complete new residency")
    # This absolute-counter check is part of calibration, NOT an assumed
    # virtual/physical offset conversion. Failure remains unknown/invalid.
    if not call["ticks"] <= entered < exited <= returned["ticks"]:
        raise ValueError("APSS does not lie inside raw platform-call interval")
    interval = (returned["ticks"] - call["ticks"]) / rate
    if abs(interval - residency) > awake + 0.1:
        raise ValueError("raw counter fails dual-clock calibration")
    if abs(duration / rate - residency) > 0.1:
        raise ValueError("APSS and dual clocks disagree")
    return dict(boot_id=pre["boot_id"], build_id=pre["build_id"],
                window_s=window, awake_window_s=awake, residency_s=residency,
                apss_residency_s=duration / rate, raw_enter_interval_s=interval,
                apss_count_delta=1)


def annotate(row, call_seq, return_seq, interrupts):
    result = dict(row)
    if row["kind"] == "phase":
        result["argument"] = row["data"][0]
        result["result_or_error"] = signed(row["data"][1])
        return result
    seq = row["seq"]
    result["boundary"] = ("before_platform_call" if call_seq and seq < call_seq else
                          "inside_platform_call" if return_seq and seq < return_seq else
                          "after_platform_return" if return_seq else "unknown_no_return")
    d = row["data"]
    if row["type"] == 1:
        result["gic_hwirq"] = d[0]
        mappings = []
        for virq, info in interrupts.items():
            match = re.match(r"GICv3\s+(\d+)\s+", info.get("desc", ""))
            if match and int(match[1]) == d[0]:
                mappings.append(dict(linux_irq=virq, desc=info["desc"]))
        result["linux_irq_mappings"] = mappings
    elif row["type"] == 2:
        result.update(ipcc_hwirq=d[0], client=d[1], signal=d[2],
                      linux_irq=d[3], summary_linux_irq=d[4])
        if d[0] != (d[1] << 16 | d[2]):
            raise ValueError("IPCC hwirq/client/signal inconsistent")
    else:
        if d[0] not in (0, 1, 2) or d[7] & ~3:
            raise ValueError("unknown PMIC action/flags")
        result["action"] = ("RX", "TX_ATTEMPT", "TX_RESULT")[d[0]]
        result["len"] = d[4]
        result["header_valid"] = bool(d[7] & 1)
        if d[7] & 1:
            if d[4] < 12:
                raise ValueError("short PMIC message marked header-valid")
            result.update(owner=d[1], message_type=d[2], opcode=d[3])
        elif d[4] >= 12 or any(d[1:4]):
            raise ValueError("PMIC header flag inconsistent")
        if d[7] & 2:
            if (d[0], d[1], d[2], d[3], d[4]) != (0, 32778, 2, 7, 16) or \
                    d[5] not in (0x30, 0x32, 0x34, 0x50, 0x80, 0x81):
                raise ValueError("invalid battery notification metadata")
            result["notification_code"] = d[5]
        elif d[5]:
            raise ValueError("unexpected notification value")
        if d[0] == 2:
            result["return_code"] = signed(d[6])
            result["send_succeeded"] = signed(d[6]) == 0
    return result


def decode(events_text, status_text, pairs):
    status = parse_status(status_text)
    if status.get("version") != "1" or status.get("state") != "sealed":
        raise ValueError("requires version=1 state=sealed")
    if len(events_text) > 2 * 1024**2:
        raise ValueError("events input too large")
    rows = [json.loads(line) for line in events_text.splitlines()]
    if len(rows) < 3 or any(not isinstance(r, dict) for r in rows):
        raise ValueError("incomplete JSONL recording")
    header, footer = rows[0], rows[-1]
    if header.get("kind") != "header" or footer.get("kind") != "footer":
        raise ValueError("missing header/footer")
    if header.get("version") != 1 or header.get("state") != "sealed":
        raise ValueError("unknown events version/state")
    for name in ("cycle", "attempt", "rate_hz", "buffer_bytes"):
        if integer(header.get(name), name) != number(status, name):
            raise ValueError(f"events/status mismatch: {name}")
    if header["buffer_bytes"] > 128 * 1024:
        raise ValueError("buffer exceeds contract")
    if not re.fullmatch(r"[0-9a-f]{40}", header.get("build_id", "")) or \
            header["build_id"] != status.get("build_id"):
        raise ValueError("missing/inconsistent recording Build ID")
    if header.get("partition") != "first_enter_return" or \
            status.get("partition") != "first_enter_return":
        raise ValueError("unknown partition")
    body = rows[1:-1]
    if not body:
        raise ValueError("recording has no body")
    for r in body:
        if r.get("kind") not in ("phase", "event"):
            raise ValueError("unknown record kind")
        for name in ("seq", "ticks", "cycle", "attempt", "type", "cpu"):
            integer(r.get(name), name)
        if (r["cycle"] != header["cycle"] or r["attempt"] > header["attempt"] or
                r["cpu"] >= 8 or r["phase"] not in PHASES or not r["seq"]):
            raise ValueError("invalid record identity/phase/CPU")
        if not isinstance(r.get("data"), list) or len(r["data"]) != 8:
            raise ValueError("invalid record metadata length")
        for d in r["data"]:
            integer(d, "data", high=2**32 - 1)
        if r["kind"] == "phase":
            if r["type"] != 0 or r.get("zone") != "phase":
                raise ValueError("invalid phase record")
        elif r["type"] not in (1, 2, 3) or r.get("zone") not in ("pre", "post"):
            raise ValueError("invalid event type/zone")
    body.sort(key=lambda r: r["seq"])
    if len({r["seq"] for r in body}) != len(body):
        raise ValueError("duplicate sequence number")
    if body[-1]["seq"] > integer(footer.get("last_seq"), "last_seq"):
        raise ValueError("record exceeds last sequence")
    phases = [r for r in body if r["kind"] == "phase"]
    for key in ("phase_count", "phase_dropped", "cpu_dropped"):
        if integer(footer.get(key), key) != number(status, key):
            raise ValueError(f"footer/status mismatch: {key}")
    if len(phases) != footer["phase_count"]:
        raise ValueError("phase count mismatch")
    issues, limits = [], []
    if footer["phase_dropped"] or footer["cpu_dropped"]:
        issues.append("phase_or_cpu_overflow")
    names = [r["phase"] for r in phases]
    if not names or names[0] != "CYCLE_BEGIN" or names[-1] != "CYCLE_END":
        issues.append("missing_cycle_boundary")
    calls = [r for r in phases if r["phase"] == "ENTER_CALL"]
    returns = [r for r in phases if r["phase"] == "ENTER_RETURN"]
    if len(calls) != header["attempt"]:
        issues.append("attempt_marker_mismatch")
    if len(calls) > 1:
        issues.append("multiple_attempts_partitioned_at_first_return")
    call, returned = (calls[0] if calls else None), (returns[0] if returns else None)
    cs, rs = call["seq"] if call else None, returned["seq"] if returned else None
    if call and (not returned or returned["seq"] <= call["seq"]):
        issues.append("missing_or_reversed_enter_return")
    if call and returned and len(calls) == 1:
        if [n for n in names if n in NORMAL] != list(NORMAL):
            issues.append("missing_or_out_of_order_normal_markers")
    if any(signed(r["data"][1]) for r in phases if r["phase"] in ("ENTER_RETURN", "CYCLE_END", "ERROR")):
        issues.append("suspend_or_enter_error")
    pseq = [r["seq"] for r in phases]
    for r in body:
        if r["kind"] != "event":
            continue
        if (r["zone"] == "post") != bool(rs and r["seq"] > rs):
            issues.append("event_partition_mismatch")
        index = bisect.bisect_right(pseq, r["seq"]) - 1
        if index < 0 or phases[index]["phase"] != r["phase"]:
            issues.append("event_phase_mismatch")
    overwritten = dropped = 0
    for cpu in range(8):
        for typ in (1, 2, 3):
            prefix = f"cpu{cpu}_type{typ}_"
            pre, post = number(status, prefix + "pre_seen"), number(status, prefix + "post_seen")
            over, drop = number(status, prefix + "pre_overwritten"), number(status, prefix + "post_dropped")
            if over != max(0, pre - 16) or drop != max(0, post - 32):
                raise ValueError("inconsistent lane counters")
            for zone, count, cap in (("pre", pre, 16), ("post", post, 32)):
                kept = sum(r["kind"] == "event" and r["cpu"] == cpu and
                           r["type"] == typ and r["zone"] == zone for r in body)
                if kept != min(count, cap):
                    raise ValueError("retained lane count mismatch")
            overwritten += over
            dropped += drop
    if overwritten:
        limits.append("pre_tail_overwritten_do_not_infer_no_earlier_TX")
    if dropped:
        limits.append("post_tail_dropped_first_records_preserved")
    ordered_ticks = all(b["ticks"] >= a["ticks"] for a, b in zip(body, body[1:]))
    rate = header["rate_hz"]
    clock_valid = False
    metrics, matched, candidates = None, None, []
    if call and returned and returned["ticks"] > call["ticks"] and rate > 0 and ordered_ticks:
        for event_id, pair in pairs.items():
            if "pre" not in pair or "post" not in pair:
                continue
            try:
                measure = observer_metrics(pair["pre"], pair["post"], call, returned,
                                           rate, header["build_id"])
            except (ValueError, TypeError, KeyError):
                continue
            candidates.append((event_id, measure, pair))
    if len(candidates) == 1 and len(calls) == len(returns) == 1:
        matched, metrics, pair = candidates[0]
        clock_valid = True
        interrupts = pair["post"].get("interrupts", {})
    else:
        interrupts = {}
        limits.append("clock_invalid_no_unique_APSS_dual_clock_calibration")
    if not ordered_ticks:
        limits.append("raw_counter_not_monotonic")
    if call and not clock_valid:
        issues.append("clock_invalid")
    timeline = [annotate(r, cs, rs, interrupts) for r in body]
    for r in timeline:
        if clock_valid:
            r["relative_to_enter_call_s"] = (r["ticks"] - call["ticks"]) / rate
    first_gic = next((r for r in timeline if r["type"] == 1 and rs and r["seq"] > rs), None)
    outcome = ("unknown_incomplete_or_error" if issues else
               "platform_return_recorded" if call and returned else "enter_not_called")
    return dict(version=1, outcome=outcome, clock_valid=clock_valid,
                issues=sorted(set(issues)), limitations=limits,
                observer_event_id=matched, calibration=metrics,
                first_dispatched_gic_after_return=first_gic,
                pre_overwritten=overwritten, post_dropped=dropped,
                physical_wake_source="unknown_not_inferred_from_first_dispatch",
                cycle=header["cycle"], attempts=header["attempt"],
                build_id=header["build_id"], timeline=timeline)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ("events", "status", "observers", "output"):
        p.add_argument(f"--{name}", type=Path, required=True)
    args = p.parse_args()
    if args.output.exists():
        p.error(f"output exists: {args.output}")
    try:
        result = decode(args.events.read_text(), args.status.read_text(),
                        read_observers(args.observers))
    except (ValueError, KeyError, TypeError, OSError, tarfile.TarError) as exc:
        p.error(str(exc))
    with args.output.open("x") as handle:
        json.dump(result, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    print(json.dumps({k: v for k, v in result.items() if k != "timeline"}, ensure_ascii=False))


if __name__ == "__main__":
    main()
