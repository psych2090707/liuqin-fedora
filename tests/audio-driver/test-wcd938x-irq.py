#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Run the real callback with mock IRQ/regmap IO; no device or kernel loaded.

RX has no regmap. The unfixed callback must hit the invalid-access sentinel,
while the fixed callback must still dispatch the codec IRQ. TX must retain
its status-drain behavior. This is control-flow evidence, not hardware proof.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile


STUBS = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uint32_t u32;
#define IRQ_HANDLED 1
#define WCD938X_DIGITAL_INTR_STATUS_0 0x346e
#define WCD938X_DIGITAL_INTR_STATUS_1 0x346f
#define WCD938X_DIGITAL_INTR_STATUS_2 0x3470
struct irq_domain { unsigned int irq; };
struct regmap { unsigned int reads; unsigned int pending_rounds; };
struct device { void *priv; };
struct sdw_slave { struct device dev; };
struct sdw_slave_intr_status { int unused; };
struct wcd938x_sdw_priv {
    struct irq_domain *slave_irq;
    struct regmap *regmap;
};
static unsigned int dispatched;
static void *dev_get_drvdata(struct device *dev) { return dev->priv; }
static unsigned int irq_find_mapping(struct irq_domain *domain, unsigned int hwirq)
{
    assert(domain && !hwirq);
    return domain->irq;
}
static void handle_nested_irq(unsigned int irq)
{
    assert(irq == 17);
    ++dispatched;
}
static int regmap_read(struct regmap *map, unsigned int reg, unsigned int *value)
{
    if (!map) {
        fputs("INVALID_REGMAP_ACCESS\n", stderr);
        exit(90);
    }
    assert(reg == WCD938X_DIGITAL_INTR_STATUS_0 + map->reads % 3);
    *value = map->reads / 3 < map->pending_rounds;
    ++map->reads;
    return 0;
}
'''

MAIN = r'''
int main(int argc, char **argv)
{
    struct irq_domain domain = { .irq = 17 };
    struct regmap map = { 0 };
    struct wcd938x_sdw_priv wcd = { .slave_irq = &domain };
    struct sdw_slave slave = { .dev = { .priv = &wcd } };
    struct sdw_slave_intr_status status = { 0 };
    unsigned int expected_rounds;
    assert(argc == 2);
    if (!strcmp(argv[1], "rx")) {
        expected_rounds = 1;
    } else {
        wcd.regmap = &map;
        map.pending_rounds = !strcmp(argv[1], "tx-pending");
        expected_rounds = map.pending_rounds + 1;
    }
    assert(wcd9380_interrupt_callback(&slave, &status) == IRQ_HANDLED);
    assert(dispatched == expected_rounds);
    assert(map.reads == (wcd.regmap ? 3 * expected_rounds : 0));
    printf("%s: dispatch=%u regmap_reads=%u\n", argv[1], dispatched, map.reads);
    return 0;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True,
                        help='actual sound/soc/codecs/wcd938x-sdw.c')
    parser.add_argument('--expect-vulnerable', action='store_true',
                        help='negative control: RX must reach invalid-access sentinel')
    args = parser.parse_args()
    source = args.source.read_text()
    start = source.index('static int wcd9380_interrupt_callback(')
    end = source.index('\n}\n', start) + 3
    callback = source[start:end]
    with tempfile.TemporaryDirectory(prefix='wcd938x-irq-test-') as tmp:
        path = Path(tmp)
        (path / 'callback.c').write_text(STUBS + callback + MAIN)
        subprocess.run(['cc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                        '-Wno-unused-parameter', str(path / 'callback.c'),
                        '-o', str(path / 'callback')], check=True)
        for case in ('tx-clear', 'tx-pending', 'rx'):
            result = subprocess.run([str(path / 'callback'), case],
                                    text=True, capture_output=True, timeout=5)
            expected = 90 if case == 'rx' and args.expect_vulnerable else 0
            if result.returncode != expected:
                raise SystemExit(f'{case}: expected {expected}, got '
                                 f'{result.returncode}\n{result.stdout}{result.stderr}')
            if expected == 90:
                assert 'INVALID_REGMAP_ACCESS' in result.stderr
                print('rx negative control: invalid regmap access reproduced')
            else:
                print(result.stdout.strip())


if __name__ == '__main__':
    main()
