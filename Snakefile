
# SANDPIPER_VERSION: '21'

# KINGFISHER_METADATA_DATE: '20220627'
# ACCESSIONS_FILE: ../sra_metadata/sra_metadata_20220209.accessions

# BIOPROJECT_METADATA_DATE: '20220711'

# JSON_METADATA_FILES: '../sra_metadata/sra_metadata_20220209/*'

# CONDENSED_OTU_TABLE: '~/m/msingle/mess/102_r207_renew_of_dec_2021_sras/sra102_r207_mach2.condense.csv.gz'
# OTU_TABLE: '~/m/msingle/mess/102_r207_renew_of_dec_2021_sras/sra102_r207.otu_table.csv.gz'
# HOST_OR_NOT_PREDICTION_GZ: '/home/woodcrob/m/big_data_microbiome/9_organism_prediction_r207/output_mach2/host_or_not_prediction/host_or_not_preds.csv.gz'

gdtb_version = '08-RS214'
renewed_output_base_directory = '~/m/msingle/mess/126_r214_renew_of_sra/renew_outputs'
base_output_directory = '20230519'
prefix = f'sra_20211215.{gdtb_version}.mach1-'
acc_organism = '/home/woodcrob/m/big_data_microbiome/9_organism_prediction_r207/acc_organism.csv'

singlem_base_directory = '~/git/singlem'
singlem_bin = f'{singlem_base_directory}/bin/singlem'

## Output paths
condensed_table = os.path.join(base_output_directory, 'condensed.csv.gz')
condensed_filled_table = os.path.join(base_output_directory, 'condensed.filled.csv.gz')

rule generate_condensed_otu_table:
    output:
        condensed_table = condensed_table,
        condensed_table_list = os.path.join(base_output_directory, 'condensed.csv.gz.list'),
        done = os.path.join(base_output_directory, 'condensed.done'),
    conda:
        "singlem-dev"
    shell:
        "find {renewed_output_base_directory} -name '*condensed.csv' > {output.condensed_table_list} && " \
        "cat <(head -1 `head -1 {output.condensed_table_list}) <(cat {output.condensed_otu_table_list} |parallel --ungroup -j1 tail -n+2 {{}}) |pigz >{output.condensed_table} && " \
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
        condensed_profile='{}/generate_profiles_from_condensed/{}2.csv.gz'.format(base_output_directory, prefix),
        done='{}/generate_profiles_from_condensed/done'.format(base_output_directory)
    conda:
        'envs/host_or_not_prediction.yml'
    shell:
        'PYTHONPATH={singlem_base_directory} ./bin/generate_profiles_from_condensed --condensed-otu-table <(zcat {input.condensed_table}) --output-prefix {base_output_directory}/generate_profiles_from_condensed/{config[PREFIX]} && ' \
        'pigz {base_output_directory}/generate_profiles_from_condensed/{prefix}*.csv && ' \
        'touch {output.done}'

rule generate_predictor:
    input:
        condensed_profile='{}/generate_profiles_from_condensed/{}2.csv.gz'.format(base_output_directory, prefix),
        done='{}/generate_profiles_from_condensed/done'.format(base_output_directory)
    output:
        done='{}/host_or_not_prediction/done'.format(base_output_directory),
        joblib='{}/host_or_not_prediction/host_or_not.joblib'.format(base_output_directory),
        column_names='{}/host_or_not_prediction/host_or_not_column_names.csv'.format(base_output_directory)
    conda:
        'envs/host_or_not_prediction.yml'
    shell:
        './bin/generate_predictor --input-gz-profile {input.condensed_profile} --acc-organism-csv {acc_organism} --sra-taxonomy-table {config[TAXONOMY_JSON]} --output-joblib {output.joblib} --output-column-names {output.column_names} && ' \
        'touch {output.done}'

rule apply_predictor:
    input:
        joblib='{}/host_or_not_prediction/host_or_not.joblib'.format(base_output_directory),
        column_names='{}/host_or_not_prediction/host_or_not_column_names.csv'.format(base_output_directory),
        condensed_profile='{}/generate_profiles_from_condensed/{}2.csv.gz'.format(base_output_directory, prefix)
    output:
        preds='{}/host_or_not_prediction/host_or_not_preds.csv'.format(base_output_directory),
        done='{}/host_or_not_prediction/apply_predictor/done'.format(base_output_directory)
    conda:
        'envs/host_or_not_prediction.yml'
    shell:
        './bin/predict_host_or_not --model {input.joblib} --columns-file {input.column_names} --acc-organism-csv {acc_organism} --condensed-profiles {input.condensed_profile} --output {output.preds} && ' \
        'touch {output.done}'
