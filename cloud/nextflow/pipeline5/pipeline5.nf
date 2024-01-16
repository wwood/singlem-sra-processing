
process singlem {
    // Dynamically add CPU and RAM - helps fix the small proportion of jobs that
    // fail due to insufficient resources. However, unsure how to adjust if the
    // job fails due to SPOT preemption. So we set a maximum of 1 retry (so 2
    // attempts in total max).

    // Choose a specific machine, because nextflow/batch isn't choosing the most
    // economical machine (e2-medium), because vCPUs are shared there, unlike in
    // the n2d series. However, still need to set cpus and memory, because
    // otherwise the job will not be given the full resources (or at least
    // that's the way it appears on google batch - maybe not actually true).
    // But, may as well.
    machineType = { task.attempt == 1 ? 't2d-standard-1' : 't2d-standard-2'}
    cpus { task.attempt == 1 ? 1 : 2}
    memory { task.attempt == 1 ? 4.GB : 8.GB }
    time '24h'
    // disk '5GB' // default is 30 so we are cutting costs? This directive doesn't seem to achieve anything, so commenting out

    // 125 was the exitstatus I observed when the batch job was preempted. But I need to retry either way with increased resources
    errorStrategy = { task.attempt <= 1 || task.exitStatus==14 || task.exitStatus == 125 ? 'retry' : 'ignore' }

    publishDir {params.base_publishDir + "${sra_identifier.substring(0,7)}"}, mode: 'move' 

    input:
      val sra_identifier

    output:
      path "${sra_identifier}*.json.gz"

    """
    /tmp/singlem/extras/singlem_an_sra.py --sra-identifier ${sra_identifier} --metapackage /mpkg
    """
}

workflow {
    def sra_ids = Channel.fromList(file(params.sra_accessions_file_dir + params.sra_accessions_file).readLines())
    singlem(sra_ids)
}
