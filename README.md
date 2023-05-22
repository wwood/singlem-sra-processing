Processing of public metagenomic data that has been analysed with SingleM.

Not intended for public usage as many paths etc are specific to CMR / QUT / Woodcroft group.

Usage:

First modify paths at the top of the Snakemake
    
Then setup:
```
mamba env create -p env_singlem_sra_processing -f env.yml
conda activate ./env_singlem_sra_processing
```

and run
```
snakemake --use-conda --cores 1
```

Make sure the correct taxonomic level is chosen for applying predictions in the Snakemake file. See 
`{base_output_directory}/logs/host_or_not_prediction.log` for the results of the cross validation.
