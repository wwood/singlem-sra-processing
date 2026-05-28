#!/usr/bin/env python3

import argparse
import glob
import logging
import sys
import polars as pl

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--chunk-dir', required=True, help='Directory containing chunk_*.tsv files')
    parser.add_argument('--output', required=True, help='Output TSV file path')
    parser.add_argument('--debug', action='store_true')
    args = parser.parse_args()

    logging.basicConfig(level=logging.DEBUG if args.debug else logging.INFO,
                        format='%(asctime)s %(levelname)s: %(message)s')

    tsv_files = sorted(glob.glob(f'{args.chunk_dir}/chunk_*.tsv'))
    if not tsv_files:
        logging.error("No chunk_*.tsv files found in %s" % args.chunk_dir)
        sys.exit(1)

    logging.info("Merging %d chunk TSV files" % len(tsv_files))

    chunks = [
        pl.scan_csv(path, separator='\t', infer_schema=False, truncate_ragged_lines=True)
        for path in tsv_files
    ]

    merged = pl.concat(chunks, how='diagonal_relaxed')
    logging.info("Streaming merged output to %s" % args.output)

    merged.sink_csv(args.output, separator='\t', null_value='')
    logging.info("Written to %s" % args.output)
