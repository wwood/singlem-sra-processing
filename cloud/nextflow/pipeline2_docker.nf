params.sra_accession = 'SRR8653040'
// SRR8653040 is a tiny one but has a few hits

process singlem {
    beforeScript 'chmod o+rw .'

    output:
    path "${params.sra_accession}*.json.gz"

    """
    /tmp/singlem/extras/singlem_an_sra.py --sra-identifier ${params.sra_accession} --metapackage /mpkg --debug
    """
}

workflow {
    singlem()
}
