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
    parent_parser.add_argument('--acc-organism-csv', help='The input acc-organism mapping file', required=True)

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
    # Remove organism column from host predictions, as it is not needed in the summary and will be added later from the acc-organism mapping
    hp = hp.select(pl.exclude('organism'))

    # Read metagenome sizes
    # logging.info('Reading metagenome sizes')
    # ms = pl.read_csv(args.input_metagenome_sizes, separator='\t')
    # logging.info(f'Read {len(ms)} metagenome sizes')

    merged1 = mf.join(hp, left_on='sample', right_on='acc', how='outer')
    # Remove the acc column from the host predictions, as it is redundant
    merged1 = merged1.select(pl.exclude('acc'))

    # Read acc-organism mapping
    acc_organism_csv = pl.read_csv(args.acc_organism_csv, has_header=True)
    # remove bioproject column
    acc_organism_csv = acc_organism_csv.select(pl.exclude('bioproject'))
    merged2 = merged1.join(acc_organism_csv, left_on='sample', right_on='acc', how='left')

    logging.info(f'In merged2, columns are: {merged2.columns}')


    # When host_or_not is missing, set to prediction
    # Log how many rows have missing host_or_not before filling
    missing_host_or_not = merged2.filter(pl.col('host_or_not').is_null())
    logging.info(f'{len(missing_host_or_not)} rows have missing host_or_not before filling')
    merged2 = merged2.with_columns(pl.when(pl.col('host_or_not').is_null()).then(pl.col('prediction')).otherwise(pl.col('host_or_not')).alias('host_or_not'))
    logging.info(f'{len(merged2.filter(pl.col("host_or_not").is_null()))} rows have missing host_or_not after filling')

    # Rename read_fraction as singlem prokaryotic fraction
    merged2 = merged2.rename({'read_fraction': 'singlem_prokaryotic_fraction'})

    logging.info("Reading coverages and calculating - takes some time.")
    profile_ids = []
    profile_root_coverage = []
    profile_species_coverage = []
    profile_top1_order_fraction = []
    profile_top3_order_fraction = []
    profile_low_complexity = []

    with open(args.profile, 'r') as f:
        for sample in CondensedCommunityProfile.each_sample_wise(f):
            sample_id = sample.sample

            root = sample.tree
            root_coverage = root.get_full_coverage()

            levels = ['root','domain','phylum','class','order','family','genus','species']
            level_id_to_level_name = {i: levels[i] for i in range(len(levels))}
            species_coverage = 0
            domain_coverage = 0
            phylum_coverage = 0
            class_coverage = 0
            order_full_coverages = []
            for node in sample.breadth_first_iter():
                level = level_id_to_level_name[node.calculate_level()]
                if level == 'species':
                    species_coverage += node.coverage
                elif level == 'order':
                    order_full_coverages.append(node.get_full_coverage())
                elif level == 'domain':
                    domain_coverage += node.coverage
                elif level == 'phylum':
                    phylum_coverage += node.coverage
                elif level == 'class':
                    class_coverage += node.coverage

            # Low complexity: top1 order makes up >=95% of community (excluding domain, phylum, class-level coverage)
            # Excludes reads only resolved to domain, phylum or class level from the denominator
            # so that unresolved higher-level reads don't dilute the order-level fractions.
            # Uses full subtree coverage per order so isolates resolved to species level are correctly flagged.
            # Intended to flag isolates mislabelled as metagenomes
            denominator = root_coverage - domain_coverage - phylum_coverage - class_coverage
            if denominator > 0 and order_full_coverages:
                order_coverages_sorted = sorted(order_full_coverages, reverse=True)
                top1_fraction = round(order_coverages_sorted[0] / denominator * 100, 2)
                top3 = sum(order_coverages_sorted[:3])
                top3_fraction = round(top3 / denominator * 100, 2)
                low_complexity = 'yes' if order_coverages_sorted[0] / denominator >= 0.95 else 'no'
            else:
                top1_fraction = None
                top3_fraction = None
                low_complexity = 'no'

            profile_ids.append(sample_id)
            profile_root_coverage.append(root_coverage)
            profile_species_coverage.append(species_coverage)
            profile_top1_order_fraction.append(top1_fraction)
            profile_top3_order_fraction.append(top3_fraction)
            profile_low_complexity.append(low_complexity)

    coverages = pl.DataFrame({
        'sample': profile_ids,
        'root_coverage': profile_root_coverage,
        'species_coverage': profile_species_coverage,
        'top1_order_fraction': profile_top1_order_fraction,
        'top3_order_fraction': profile_top3_order_fraction,
        'low_complexity': profile_low_complexity,
    }, schema_overrides={
        'root_coverage': pl.Float64,
        'species_coverage': pl.Float64,
        'top1_order_fraction': pl.Float64,
        'top3_order_fraction': pl.Float64,
    })
    # round(2)
    coverages = coverages.with_columns(pl.col('root_coverage').round(2))
    coverages = coverages.with_columns(pl.col('species_coverage').round(2))

    # known_species fraction should be a % like read_fraction, so multiply by 100, round to 2 decimal places
    coverages = coverages.with_columns(((pl.col('species_coverage') / pl.col('root_coverage')).alias('known_species_fraction')* 100).round(2))
    
    merged = coverages.join(merged2, on='sample', how='left')

    logging.info("Writing output ..")
    merged.write_csv(args.output)

    # Log how many rows were written overall, and how many from each of the merged datasets (coverages, microbial fractions, host predictions)
    logging.info(f'Wrote {len(merged)} rows to output')
    logging.info(f'Coverages: {len(coverages)} rows')
    logging.info(f'Microbial fractions: {len(mf)} rows')
    logging.info(f'Host predictions: {len(hp)} rows')
    logging.info(f'Acc-organism mapping: {len(acc_organism_csv)} rows')

    logging.info("Done.")


