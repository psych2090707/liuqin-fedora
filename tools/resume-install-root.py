#!/usr/bin/env python3
"""Retired TN0047 one-off installer entry; historical references stay resolvable."""
import sys

if __name__ == '__main__':
    sys.exit(
        'Retired: TN0047 root installation recovery no longer applies. '
        'The device now has one root partition containing /home; reinstalling '
        'would erase user data. Do not write or switch to unverified slot B. '
        'Use RPM/configuration updates; boot_a writes require fresh approval. '
        'See AGENTS.md and tasks/archive/TN0084-project-audit/RESULT.md. '
        'Original code is in Git 3a49060:tools/resume-install-root.py.'
    )
