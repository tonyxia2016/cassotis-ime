#!/usr/bin/env python3
"""Keep model deployment metadata limited to runtime fields and provenance."""
import argparse
import json
from pathlib import Path


def runtime_metadata(name, value):
    """Project metadata onto reviewed fields; values read by the hosts stay exact."""
    def select(obj, keys):
        return {key: obj[key] for key in keys.split()}
    if name == 'char_lm':
        return select(value, 'format architecture task quantization input_embedding custom_operators n_layer n_head n_embd '
                      'block_size vocab_size bos_id unk_id correction_context_chars source_checkpoint_sha256 files')
    raise ValueError(f'Unsupported model: {name}')



MODEL_MANIFESTS = (('char_lm', 'runtime_manifest.json'),)


def prepare(directory, check=False):
    for kind, filename in MODEL_MANIFESTS:
        path = directory/kind/filename
        value = json.loads(path.read_text())
        deployment = runtime_metadata(kind, value)
        if check:
            if value != deployment:
                raise ValueError(f'Unexpected deployment metadata fields: {kind}/{filename}')
        else:
            path.write_text(json.dumps(deployment, ensure_ascii=False, indent=2)+'\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    prepare(args.directory, args.check)
