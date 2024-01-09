params.sra_accessions_file = 'test/sra_accessions1.txt'

// SRR8653040 is a tiny one but has a few hits

process singlem {
    beforeScript 'chmod o+rw .'

    input:
      val sra_identifier

    output:
      path "${sra_identifier}*.json.gz"

    """
    /tmp/singlem/extras/singlem_an_sra.py --sra-identifier ${sra_identifier} --metapackage /mpkg --debug
    """
}

workflow {
    def sra_ids = Channel.fromList(file(params.sra_accessions_file).readLines())
    singlem(sra_ids)
}
