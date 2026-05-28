#!/usr/bin/env python3

import csv

per_acc_summary = '/home/herholdt/singlem-sra-processing/per_acc_summary.csv'

print('Reading per_acc_summary...')
rows = []
with open(per_acc_summary) as f:
    for row in csv.DictReader(f):
        rows.append({
            'sample': row['sample'],
            'organism': row['organism'],
            'low_complexity': row['low_complexity'],
            'top1_order_fraction': row['top1_order_fraction'],
            'top3_order_fraction': row['top3_order_fraction'],
        })
print(f'Read {len(rows)} rows')

with open('low_complexity_with_organism.csv', 'w', newline='') as out:
    writer = csv.DictWriter(out, fieldnames=['sample', 'organism', 'low_complexity', 'top1_order_fraction', 'top3_order_fraction'])
    writer.writeheader()
    writer.writerows(rows)

print('Saved low_complexity_with_organism.csv')
