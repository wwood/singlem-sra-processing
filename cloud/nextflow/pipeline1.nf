params.sra_accession = 'SRR8653040'
// SRR8653040 is a tiny one but has a few hits

process singlem {
    output:
    path "${params.sra_accession}*.json.gz"

    """
    ~/git/singlem/extras/singlem_an_sra.py --sra-identifier ${params.sra_accession} --metapackage ~/git/singlem/db/S3.2.1.GTDB_r214.metapackage_20231006.smpkg.zb
    """
}

workflow {
    singlem()
}
