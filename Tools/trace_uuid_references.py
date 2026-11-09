#!/usr/bin/env python3
"""Find candidate AArch64 ADRP/ADD references to audited UUID string locations.

Read-only; the binary is never executed. This is reference evidence, not recovered source or a
verified GATT role map. The following ADD must use the ADRP destination as its base. Register
clobbers between the pair are not interpreted, so every result needs manual disassembly review.
"""
import argparse
import json
from pathlib import Path
import numpy as np


def trace(binary_path, locations):
    text = locations['text_section']
    words = np.memmap(binary_path, mode='r', dtype='<u4', offset=text['offset'], shape=(text['size'] // 4,))
    indices = np.flatnonzero((words & 0x9f000000) == 0x90000000)
    instructions = words[indices].astype(np.int64)
    immediate = ((instructions >> 5) & 0x7ffff) * 4 + ((instructions >> 29) & 3)
    immediate = np.where(immediate & (1 << 20), immediate - (1 << 21), immediate)
    pc = text['address'] + indices * 4
    pages = (pc & ~4095) + (immediate << 12)
    targets = {item['address']: item['uuid'] for item in locations['uuid_candidates']}
    wanted = np.array(list({address & ~4095 for address in targets}), dtype=np.int64)
    relevant = np.flatnonzero(np.isin(pages, wanted))
    result = []
    for entry in relevant:
        index = int(indices[entry])
        register = int(instructions[entry]) & 31
        for distance in range(1, 9):
            if index + distance >= len(words):
                break
            following = int(words[index + distance])
            if following & 0xff000000 != 0x91000000:
                continue
            if ((following >> 5) & 31) != register:
                continue
            value = (following >> 10) & 0xfff
            if following & (1 << 22):
                value <<= 12
            address = int(pages[entry]) + value
            if address in targets:
                result.append(dict(uuid=targets[address], string_address=hex(address),
                                   adrp_address=hex(int(pc[entry])), add_address=hex(int(pc[entry]) + distance * 4),
                                   review_required=True))
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary')
    parser.add_argument('locations')
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    result = trace(args.binary, json.loads(Path(args.locations).read_text()))
    Path(args.output).write_text(json.dumps({'candidate_references': result,
        'limits': 'ADRP/ADD candidates only; no register-clobber/control-flow or hardware validation.'}, indent=2) + '\n')
    print('Candidate references:', len(result))
