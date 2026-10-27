#!/usr/bin/env python3
"""Expand the pinned GGML shader for Xcode's portable Metal library build."""
from pathlib import Path
import argparse

ROOT = Path(__file__).resolve().parents[2]
QWEN = ROOT / 'app/mobile/shared/qwen'
METAL = QWEN / 'vendor/ggml/src/ggml-metal'


def expanded_shader():
    source = (METAL / 'ggml-metal.metal').read_text()
    source = source.replace('__embed_ggml-common.h__', (METAL.parent / 'ggml-common.h').read_text())
    source = source.replace('#include "ggml-metal-impl.h"', (METAL / 'ggml-metal-impl.h').read_text())
    return '// Generated from pinned GGML sources; see PROVENANCE.json.\n#define GGML_METAL_EMBED_LIBRARY 1\n' + source


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    target = QWEN / 'metal-shaders/ggml-metal.metal'
    source = expanded_shader()
    if args.check:
        if not target.exists() or target.read_text() != source:
            raise SystemExit('Regenerate the Qwen Metal shader with this script.')
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(source)
