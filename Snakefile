
# SANDPIPER_VERSION: '21'

# KINGFISHER_METADATA_DATE: '20220627'
# ACCESSIONS_FILE: ../sra_metadata/sra_metadata_20220209.accessions

# BIOPROJECT_METADATA_DATE: '20220711'

# JSON_METADATA_FILES: '../sra_metadata/sra_metadata_20220209/*'

# CONDENSED_OTU_TABLE: '~/m/msingle/mess/102_r207_renew_of_dec_2021_sras/sra102_r207_mach2.condense.csv.gz'
# OTU_TABLE: '~/m/msingle/mess/102_r207_renew_of_dec_2021_sras/sra102_r207.otu_table.csv.gz'
# HOST_OR_NOT_PREDICTION_GZ: '/home/woodcrob/m/big_data_microbiome/9_organism_prediction_r207/output_mach2/host_or_not_prediction/host_or_not_preds.csv.gz'

gdtb_version = '08-RS214'
renewed_output_base_directory = '/work/microbiome/msingle/mess/141_sra_renew_singlem_0.17_approx/renew_outputs'
base_output_directory = '/work/microbiome/msingle/mess/141_sra_renew_singlem_0.17_approx/processing_20231016'
predictor_prefix = f'sra_20211215.{gdtb_version}.mach2-'
acc_organism = '/work/microbiome/big_data_microbiome/9_organism_prediction_r207/acc_organism.csv'
taxonomy_json = '/work/microbiome/big_data_microbiome/9_organism_prediction_r207/sra_taxonomy_table_20220208_sandpiper_5samples_mach3.json'
sra_num_bases = '/work/microbiome/msingle/mess/117_read_fraction_of_sra/sra_20211215.num_bases'


tested_depth_indices = [2,3,4] # test phylum class order
predictor_chosen_taxonomy_depth_index = 4

singlem_base_directory = '~/git/singlem'
singlem_bin = f'{singlem_base_directory}/bin/singlem'

## Output paths
condensed_table = os.path.join(base_output_directory, 'condensed.csv.gz')
condensed_filled_table = os.path.join(base_output_directory, 'condensed.filled.csv.gz')
otu_table = os.path.join(base_output_directory, 'otu_table.csv.gz')
microbial_fractions = os.path.join(base_output_directory, 'microbial_fractions.csv')

# mkdir '{}/logs'.format(base_output_directory)
os.makedirs('{}/logs'.format(base_output_directory), exist_ok=True)

rule all:
    input:
        [f'{base_output_directory}/logs/host_or_not_prediction-level{depth_index}.log' for depth_index in tested_depth_indices],
        '{}/host_or_not_prediction/apply_predictor/done'.format(base_output_directory),
        condensed_filled_table,
        otu_table,
        microbial_fractions,

rule generate_actual_otu_table:
    # Remove off-target sequences, but otherwise
    output:
        otu_table = otu_table,
        done = os.path.join(base_output_directory, 'otu_table.done'),
    conda:
        "singlem-dev"
    shell:
        "rm -f {log} && find {renewed_output_base_directory} -name '*json' " \
        "|parallel -j20 --eta -N 50 {singlem_base_directory}/bin/singlem summarise --input-archive-otu-table {{}} --exclude-off-target-hits --output-otu-table /dev/stdout --quiet '|' tail -n+2" \
        "|cat otu_table_headings - |pigz >{output.otu_table} && " \
        "touch {output.done}"

rule generate_condensed_otu_table:
    output:
        condensed_table = condensed_table,
        condensed_table_list = os.path.join(base_output_directory, 'condensed.csv.gz.list'),
        done = os.path.join(base_output_directory, 'condensed.done'),
    conda:
        "singlem-dev"
    shell:
        "find {renewed_output_base_directory} -name '*condensed.csv' > {output.condensed_table_list} && " \
        "cat <(head -1 `head -1 {output.condensed_table_list}`) <(cat {output.condensed_table_list} |parallel --ungroup --eta -j1 tail -n+2 {{}}) |pigz >{output.condensed_table} && " \
        "touch {output.done}"

rule fill_condensed_otu_table:
    input:
        condensed_table = condensed_table,
        condensed_done = os.path.join(base_output_directory, 'condensed.done'),
    output:
        condensed_filled_table=condensed_filled_table,
        condensed_filled_done = os.path.join(base_output_directory, 'condensed.filled.done'),
    conda:
        "singlem-dev"
    shell:
        "{singlem_base_directory}/extras/fill_condensed_coverages --condensed-otu-table <(zcat {input.condensed_table}) --output-filled-otu-table >(pigz >{output.condensed_filled_table}) && " \
        "touch {output.condensed_filled_done}"

rule generate_taxonomy_level_profiles_from_condensed_for_predictor:
    input:
        condensed_table = condensed_table,
        done = os.path.join(base_output_directory, 'condensed.done'),
        # '{}'.format(config['INPUT_CONDENSED_PROFILE'])
    output:
        condensed_profile=[
            '{}/generate_profiles_from_condensed/{}{}.csv.gz'.format(base_output_directory, predictor_prefix, i)
            for i in tested_depth_indices],
        done='{}/generate_profiles_from_condensed/done'.format(base_output_directory)
    conda:
        'envs/host_or_not_prediction.yml'
    params:
        tested_index_string = ' '.join([str(i) for i in tested_depth_indices]),
    shell:
        'PYTHONPATH={singlem_base_directory} ./bin/generate_profiles_from_condensed --depth-index-target {params.tested_index_string} --condensed-otu-table <(zcat {input.condensed_table}) --output-prefix {base_output_directory}/generate_profiles_from_condensed/{predictor_prefix} && ' \
        'pigz {base_output_directory}/generate_profiles_from_condensed/{predictor_prefix}*.csv && ' \
        'touch {output.done}'

rule generate_predictor:
    input:
        condensed_profile='{}/generate_profiles_from_condensed/{}'.format(base_output_directory, predictor_prefix)+'{depth_index}.csv.gz',
        done='{}/generate_profiles_from_condensed/done'.format(base_output_directory)
    output:
        done='{}/host_or_not_prediction/done'.format(base_output_directory)+'{depth_index}',
        joblib='{}/host_or_not_prediction/host_or_not-'.format(base_output_directory)+'{depth_index}.joblib',
        column_names='{}/host_or_not_prediction/host_or_not_column_names'.format(base_output_directory) + '{depth_index}.csv',
        log='{}/logs/host_or_not_prediction-level'.format(base_output_directory)+'{depth_index}.log',
    conda:
        'envs/host_or_not_prediction.yml'
    threads:
        64
    shell:
        './bin/generate_predictor --input-gz-profile {input.condensed_profile} --acc-organism-csv {acc_organism} --sra-taxonomy-table {taxonomy_json} --output-joblib {output.joblib} --output-column-names {output.column_names} &> {output.log} && ' \
        'touch {output.done}'

rule apply_predictor:
    input:
        joblib='{}/host_or_not_prediction/host_or_not-'.format(base_output_directory)+f'{predictor_chosen_taxonomy_depth_index}.joblib',
        column_names='{}/host_or_not_prediction/host_or_not_column_names'.format(base_output_directory) + f'{predictor_chosen_taxonomy_depth_index}.csv',
        condensed_profile='{}/generate_profiles_from_condensed/{}{}.csv.gz'.format(base_output_directory, predictor_prefix, predictor_chosen_taxonomy_depth_index)
    output:
        preds='{}/host_or_not_prediction/host_or_not_preds.csv'.format(base_output_directory),
        done='{}/host_or_not_prediction/apply_predictor/done'.format(base_output_directory)
    conda:
        'envs/host_or_not_prediction.yml'
    shell:
        './bin/predict_host_or_not --taxonomy-json {taxonomy_json} --model {input.joblib} --columns-file {input.column_names} --acc-organism-csv {acc_organism} --condensed-profiles {input.condensed_profile} --output {output.preds} && ' \
        'touch {output.done}'

rule microbial_fraction:
    input:
        condensed_profile=condensed_table,
    output:
        fractions = microbial_fractions,
        done = touch('{}/done/microbial_fractions.done'.format(base_output_directory))
    conda:
        'singlem-dev'
    params:
        singlem_bin = singlem_bin,
        sra_num_bases = sra_num_bases
    log:
        '{}/logs/microbial_fractions.log'.format(base_output_directory)
    shell:
        '{params.singlem_bin} microbial_fraction -p <(zcat {input.condensed_profile}) --input-metagenome-sizes {params.sra_num_bases} >{output.fractions} --accept-missing-samples 2> {log}'
