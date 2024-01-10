
process singlem {
    cpus 1
    memory '4GB'
    time '6h'

    input:
      val sra_identifier

    output:
      path "${sra_identifier}*.json.gz"

    """
    /tmp/singlem/extras/singlem_an_sra.py --sra-identifier ${sra_identifier} --metapackage /mpkg
    """
}

workflow {
    def sra_ids = Channel.fromList(file(params.sra_accessions_file).readLines())
    singlem(sra_ids)
}
