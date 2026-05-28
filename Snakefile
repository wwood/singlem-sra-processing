

gdtb_version = config['GTDB_VERSION']
renewed_output_base_directory = config['RENEWED_OUTPUT_BASE_DIRECTORY']
base_output_directory = config['BASE_OUTPUT_DIRECTORY']
predictor_prefix = config['PREDICTOR_PREFIX']
metapackage_argument = config['METAPACKAGE_ARGUMENT']

acc_organism = config['ACC_ORGANISM']
taxonomy_json = config['TAXONOMY_JSON']
sra_num_bases = config['SRA_NUM_BASES']
condensed_directory = config.get('CONDENSED_DIRECTORY', renewed_output_base_directory)


tested_depth_indices = [2,3,4] # test phylum class order
tested_depth_indices = [2,3] # test phylum class. order was going out of RAM for 64GB
predictor_chosen_taxonomy_depth_index = 3 # was 4 - needs checking to make sure we are still getting good accuracy

singlem_bin = 'singlem'

## Output paths
condensed_table = os.path.join(base_output_directory, 'condensed.csv.gz')
condensed_filled_table = os.path.join(base_output_directory, 'condensed.filled.csv.gz')
otu_table = os.path.join(base_output_directory, 'otu_table.csv.gz')
microbial_fractions = os.path.join(base_output_directory, 'microbial_fractions.csv')
per_acc_summary_file = os.path.join(base_output_directory, 'per_acc_summary.csv')
accessions_file = os.path.join(base_output_directory, 'accessions.txt')
kingfisher_metadata_file = os.path.join(base_output_directory, 'kingfisher_metadata.tsv')
parsed_metadata_file = os.path.join(base_output_directory, 'parsed_metadata.tsv')
parse_biosample_extras_path = '../sandpiper/backend/sandpiper/parse_biosample_extras.py'

## Test output paths (prefixed symlinks)
test_condensed_filled_table = os.path.join(base_output_directory, 'test_condensed.filled.csv.gz')
test_otu_table = os.path.join(base_output_directory, 'test_otu_table.csv.gz')
test_microbial_fractions = os.path.join(base_output_directory, 'test_microbial_fractions.csv')
test_per_acc_summary = os.path.join(base_output_directory, 'test_per_acc_summary.csv')
test_parsed_metadata = os.path.join(base_output_directory, 'test_parsed_metadata.tsv')

# mkdir '{}/logs'.format(base_output_directory)
os.makedirs('{}/logs'.format(base_output_directory), exist_ok=True)

localrules: all

rule all:
    input:
        [f'{base_output_directory}/host_or_not_prediction/done{depth_index}' for depth_index in tested_depth_indices],
        '{}/host_or_not_prediction/apply_predictor/done'.format(base_output_directory),
        condensed_filled_table,
        otu_table,
        microbial_fractions,
        '{}/done/per_acc_summary.done'.format(base_output_directory),
        test_condensed_filled_table,
        test_otu_table,
        test_microbial_fractions,
        test_per_acc_summary,
        test_parsed_metadata,

rule generate_actual_otu_table:
    # Remove off-target sequences, but otherwise
    output:
        otu_table = otu_table,
        done = touch(os.path.join(base_output_directory, 'otu_table.done')),
    threads: 8
    resources:
        mem_mb = 64000,
        runtime = '24h',
    shell:
        # This is -j20 with threads 8 atm, but eh for now, while it is running.
        "rm -f {log} && find {renewed_output_base_directory} -name '*json' " \
        "|pixi run -e singlem parallel -j20 --eta -N 50 singlem summarise {metapackage_argument} --input-archive-otu-table {{}} --exclude-off-target-hits --output-otu-table /dev/stdout --quiet '|' tail -n+2" \
        "|cat otu_table_headings - |pigz >{output.otu_table}"

rule generate_condensed_otu_table:
    output:
        condensed_table = condensed_table,
        condensed_table_list = os.path.join(base_output_directory, 'condensed.csv.gz.list'),
        done = os.path.join(base_output_directory, 'condensed.done'),
    threads: 2
    resources:
        mem_mb = 8000,
        runtime = '24h',
    shell:
        "find {condensed_directory} -name '*condensed.csv' > {output.condensed_table_list} && " \
        "cat <(head -1 `head -1 {output.condensed_table_list}`) <(cat {output.condensed_table_list} |parallel --ungroup --eta -j1 --xargs tail -q -n+2 {{}}) |pigz >{output.condensed_table} && " \
        "touch {output.done}"

rule fill_taxonomic_profile:
    input:
        condensed_table = condensed_table,
        condensed_done = os.path.join(base_output_directory, 'condensed.done'),
    output:
        condensed_filled_table=condensed_filled_table,
        condensed_filled_done = touch(os.path.join(base_output_directory, 'condensed.filled.done')),
    threads: 1
    resources:
        mem_mb = 8000,
        runtime = '24h',
    shell:
        "pixi run -e singlem singlem summarise --input-taxonomic-profile <(zcat {input.condensed_table}) --output-filled-taxonomic-profile >(pigz >{output.condensed_filled_table})"

rule generate_taxonomy_level_profiles_from_condensed_for_predictor:
    input:
        condensed_table = condensed_table,
        done = os.path.join(base_output_directory, 'condensed.done'),
        # '{}'.format(config['INPUT_CONDENSED_PROFILE'])
    output:
        condensed_profile=[
            '{}/generate_profiles_from_condensed/{}{}.csv.gz'.format(base_output_directory, predictor_prefix, i)
            for i in tested_depth_indices],
        done=touch('{}/generate_profiles_from_condensed/done'.format(base_output_directory))
    threads: 8
    resources:
        mem_mb = 8000,
        runtime = '24h',
    params:
        tested_index_string = ' '.join([str(i) for i in tested_depth_indices]),
    shell:
        'pixi run -e singlem python ./singlem_host_or_ecological_predictor/bin/generate_profiles_from_condensed --depth-index-target {params.tested_index_string} --condensed-otu-table <(zcat {input.condensed_table}) --output-prefix {base_output_directory}/generate_profiles_from_condensed/{predictor_prefix} && ' \
        'pigz {base_output_directory}/generate_profiles_from_condensed/{predictor_prefix}*.csv'

rule generate_predictor:
    input:
        condensed_profile='{}/generate_profiles_from_condensed/{}'.format(base_output_directory, predictor_prefix)+'{depth_index}.csv.gz',
        done='{}/generate_profiles_from_condensed/done'.format(base_output_directory)
    output:
        done=touch('{}/host_or_not_prediction/done'.format(base_output_directory)+'{depth_index}'),
        joblib='{}/host_or_not_prediction/host_or_not-'.format(base_output_directory)+'{depth_index}.joblib',
        column_names='{}/host_or_not_prediction/host_or_not_column_names'.format(base_output_directory) + '{depth_index}.csv',
    log:
        '{}/logs/host_or_not_prediction-level'.format(base_output_directory)+'{depth_index}.log'
    threads: 8
    resources:
        mem_mb = 64000,
        runtime = '24h',
    conda:
        'singlem_host_or_ecological_predictor/envs/host_or_not_prediction.yml'
    threads:
        64
    shell:
        './singlem_host_or_ecological_predictor/bin/generate_predictor --input-gz-profile {input.condensed_profile} --acc-organism-csv {acc_organism} --sra-taxonomy-table {taxonomy_json} --output-joblib {output.joblib} --output-column-names {output.column_names} &> {log}'

rule apply_predictor:
    input:
        joblib='{}/host_or_not_prediction/host_or_not-'.format(base_output_directory)+f'{predictor_chosen_taxonomy_depth_index}.joblib',
        column_names='{}/host_or_not_prediction/host_or_not_column_names'.format(base_output_directory) + f'{predictor_chosen_taxonomy_depth_index}.csv',
        condensed_profile='{}/generate_profiles_from_condensed/{}{}.csv.gz'.format(base_output_directory, predictor_prefix, predictor_chosen_taxonomy_depth_index)
    output:
        preds='{}/host_or_not_prediction/host_or_not_preds.csv'.format(base_output_directory),
        done=touch('{}/host_or_not_prediction/apply_predictor/done'.format(base_output_directory))
    log:
        '{}/logs/host_or_not_prediction.log'.format(base_output_directory)
    threads: 1
    benchmark:
        '{}/benchmarks/apply_predictor.benchmark'.format(base_output_directory)
    resources:
        mem_mb = 64000, # killed with 8G
        runtime = '24h',
    conda:
        'singlem_host_or_ecological_predictor/envs/host_or_not_prediction.yml'
    shell:
        './singlem_host_or_ecological_predictor/bin/predict_host_or_not --taxonomy-json {taxonomy_json} --model {input.joblib} --columns-file {input.column_names} --acc-organism-csv {acc_organism} --condensed-profiles {input.condensed_profile} --output {output.preds} 2> {log}'

rule microbial_fraction:
    input:
        condensed_profile=condensed_table,
    output:
        fractions = microbial_fractions,
        done = touch('{}/done/microbial_fractions.done'.format(base_output_directory))
    params:
        sra_num_bases = sra_num_bases
    log:
        '{}/logs/microbial_fractions.log'.format(base_output_directory)
    threads: 1
    resources:
        mem_mb = 8000,
        runtime = '24h',
    shell:
        'pixi run -e singlem singlem microbial_fraction -p <(zcat {input.condensed_profile}) --input-metagenome-sizes {params.sra_num_bases} >{output.fractions} --accept-missing-samples {metapackage_argument} 2> {log}'

rule per_acc_summary:
    input:
        condensed_profile=condensed_table,
        fractions = microbial_fractions,
        done = '{}/done/microbial_fractions.done'.format(base_output_directory),
        preds='{}/host_or_not_prediction/host_or_not_preds.csv'.format(base_output_directory),
        done2 ='{}/host_or_not_prediction/apply_predictor/done'.format(base_output_directory),
        # sra_num_bases = sra_num_bases,
    output:
        summary = '{}/per_acc_summary.csv'.format(base_output_directory),
        done = touch('{}/done/per_acc_summary.done'.format(base_output_directory))
    log:
        '{}/logs/per_acc_summary.log'.format(base_output_directory)
    threads: 1
    resources:
        mem_mb = 8000,
        runtime = '24h',
    shell:
        ## NOTE: As of writing (sandpiper 1.1.10), this has not been tested within snakemake - it was run separately to avoid snakemake rerunning stuff.
        # "PYTHONPATH={singlem_base_directory} "
        "pixi run -e singlem ./per_acc_summary.py -p <(zcat {input.condensed_profile}) "
        "--microbial-fractions {input.fractions} "
        "-o {output.summary} "
        "--host-predictions {input.preds} "
        "--acc-organism-csv {acc_organism} " # Must read from here otherwise ones like "synthetic metagenome" will be missing from the acc-organism mapping, and thus not get the right organism in the summary.
        "2> {log}"

rule extract_accessions:
    output:
        accessions_file,
    shell:
        "find {renewed_output_base_directory} -name '*json' | sed 's/.*\\///' | sed 's/\\.json$//' | sort -u > {output}"

rule run_kingfisher_annotate:
    input:
        accessions = accessions_file,
    output:
        metadata = kingfisher_metadata_file,
        done = touch(os.path.join(base_output_directory, 'done/kingfisher_annotate.done')),
    log:
        os.path.join(base_output_directory, 'logs/kingfisher_annotate.log'),
    threads: 4
    resources:
        mem_mb = 128000,
        runtime = '24h',
    params:
        chunk_dir = os.path.join(base_output_directory, 'kingfisher_chunks'),
        n_chunks = 4,
    shell:
        "rm -rf {params.chunk_dir} && mkdir -p {params.chunk_dir} && "
        "split -n l/{params.n_chunks} {input.accessions} {params.chunk_dir}/chunk_ && "
        "ls {params.chunk_dir}/chunk_* | parallel -j {threads} --retries 10 --delay 60 "
        "'NCBI_API_KEY=" + config.get('NCBI_API_KEY', '') + " pixi run -e kingfisher kingfisher annotate -f tsv --all-columns --run-identifiers-list {{}} -o {{}}.tsv > {{}}.log 2>&1' && "
        "cat {params.chunk_dir}/chunk_*.log > {log} && "
        "pixi run -e singlem python merge_tsv_chunks.py --chunk-dir {params.chunk_dir} --output {output.metadata}"

rule generate_parsed_metadata:
    input:
        metadata = kingfisher_metadata_file,
        done = os.path.join(base_output_directory, 'done/kingfisher_annotate.done'),
    output:
        parsed_metadata = parsed_metadata_file,
        done = touch(os.path.join(base_output_directory, 'done/parsed_metadata.done')),
    log:
        os.path.join(base_output_directory, 'logs/parsed_metadata.log'),
    threads: 1
    resources:
        mem_mb = 8000,
        runtime = '24h',
    shell:
        "pixi run -e singlem python {parse_biosample_extras_path} --kingfisher-annotate-tsvs {input.metadata} --extra-sample-keys depth temperature collection_date > {output.parsed_metadata} 2> {log}"

rule create_test_outputs:
    input:
        condensed_filled = condensed_filled_table,
        otu_table = otu_table,
        microbial_fractions = microbial_fractions,
        per_acc_summary = per_acc_summary_file,
        per_acc_summary_done = '{}/done/per_acc_summary.done'.format(base_output_directory),
        parsed_metadata = parsed_metadata_file,
        parsed_metadata_done = os.path.join(base_output_directory, 'done/parsed_metadata.done'),
    output:
        condensed_filled = test_condensed_filled_table,
        otu_table = test_otu_table,
        microbial_fractions = test_microbial_fractions,
        per_acc_summary = test_per_acc_summary,
        parsed_metadata = test_parsed_metadata,
    shell:
        "ln -sf {input.condensed_filled} {output.condensed_filled} && "
        "ln -sf {input.otu_table} {output.otu_table} && "
        "ln -sf {input.microbial_fractions} {output.microbial_fractions} && "
        "ln -sf {input.per_acc_summary} {output.per_acc_summary} && "
        "ln -sf {input.parsed_metadata} {output.parsed_metadata}"