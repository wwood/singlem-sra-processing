#!/usr/bin/env python3

###############################################################################
#
#    Copyright (C) 2024 Ben Woodcroft
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
###############################################################################

__author__ = "Ben Woodcroft"
__copyright__ = "Copyright 2024"
__credits__ = ["Ben Woodcroft"]
__license__ = "GPL3"
__maintainer__ = "Ben Woodcroft"
__email__ = "benjwoodcroft near gmail.com"
__status__ = "Development"

import argparse
import logging
import sys
import os
import polars as pl

from singlem.condense import CondensedCommunityProfile

sys.path = [os.path.join(os.path.dirname(os.path.realpath(__file__)),'..')] + sys.path

if __name__ == '__main__':
    parent_parser = argparse.ArgumentParser(add_help=False)
    parent_parser.add_argument('--debug', help='output debug information', action="store_true")
    #parent_parser.add_argument('--version', help='output version information and quit',  action='version', version=repeatm.__version__)
    parent_parser.add_argument('--quiet', help='only output errors', action="store_true")
    
    # "./per_acc_summary.py -p <(zcat {input.condensed_profile}) "
    # "--microbial-fractions {input.fractions} "
    # "-o {output.summary} "
    # "--host-predictions {input.preds} "
    # "--input-metagenome-sizes {input.sra_num_bases} 2> {log}"

    parent_parser.add_argument('-p', '--profile', help='The input condensed profile file', required=True)
    parent_parser.add_argument('-o', '--output', help='The output summary file', required=True)
    parent_parser.add_argument('--microbial-fractions', help='The input microbial fractions file', required=True)
    parent_parser.add_argument('--host-predictions', help='The input host predictions file', required=True)
    # parent_parser.add_argument('--input-metagenome-sizes', help='The input metagenome sizes file', required=True)

    args = parent_parser.parse_args()

    # Setup logging
    if args.debug:
        loglevel = logging.DEBUG
    elif args.quiet:
        loglevel = logging.ERROR
    else:
        loglevel = logging.INFO
    logging.basicConfig(level=loglevel, format='%(asctime)s %(levelname)s: %(message)s', datefmt='%Y/%m/%d %I:%M:%S %p')

    # Read microbial fractions
    logging.info('Reading microbial fractions')
    mf = pl.read_csv(args.microbial_fractions, separator='\t')
    logging.info(f'Read {len(mf)} microbial fractions')

    # Read host predictions
    logging.info('Reading host predictions')
    hp = pl.read_csv(args.host_predictions, separator='\t')
    logging.info(f'Read {len(hp)} host predictions')

    # Read metagenome sizes
    # logging.info('Reading metagenome sizes')
    # ms = pl.read_csv(args.input_metagenome_sizes, separator='\t')
    # logging.info(f'Read {len(ms)} metagenome sizes')

    merged1 = mf.join(hp, left_on='sample', right_on='acc')

    logging.info("Reading coverages and calculating - takes some time.")
    profile_ids = []
    profile_root_coverage = []
    profile_species_coverage = []

    with open(args.profile, 'r') as f:
        for sample in CondensedCommunityProfile.each_sample_wise(f):
            sample_id = sample.sample

            root = sample.tree
            root_coverage = root.get_full_coverage()

            levels = ['root','domain','phylum','class','order','family','genus','species']
            level_id_to_level_name = {i: levels[i] for i in range(len(levels))}
            species_coverage = 0
            for node in sample.breadth_first_iter():
                if level_id_to_level_name[node.calculate_level()] == 'species':
                    species_coverage += node.coverage

            profile_ids.append(sample_id)
            profile_root_coverage.append(root_coverage)
            profile_species_coverage.append(species_coverage)

    coverages = pl.DataFrame({
        'sample': profile_ids,
        'root_coverage': profile_root_coverage,
        'species_coverage': profile_species_coverage
    })
    coverages = coverages.with_columns(pl.col('species_coverage') / pl.col('root_coverage').alias('known_species_fraction'))
    
    merged = coverages.join(merged1, on='sample')

    logging.info("Writing output ..")
    merged.write_csv(args.output)

    logging.info("Done.")


